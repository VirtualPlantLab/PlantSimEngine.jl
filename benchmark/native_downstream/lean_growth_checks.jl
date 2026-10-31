module LeanGrowthChecks

using Dates, Test, PlantSimEngine
const PSE = PlantSimEngine
const Growth = Main.LeanNativeGrowth
const CR = Main.CompiledRegionsExperiment
const XP = Main.NativeXPDriver
if !isdefined(Main, :LeanReadableSource)
    Base.include(Main, joinpath(@__DIR__, "lean_inspection_models.jl"))
end

export growth_generic_checks, growth_mutation_checks, growth_xp_checks,
    growth_inspection_checks, growth_reference_checks, growth_xp_reference_checks,
    growth_all_checks

PSE.@process "lean_growth_creator" verbose=false
PSE.@process "lean_growth_numeric" verbose=false
PSE.@process "lean_growth_collector" verbose=false

struct GrowthCreator <: AbstractLean_Growth_CreatorModel
    limit::Int
end
PSE.inputs_(::GrowthCreator) = (;)
PSE.outputs_(::GrowthCreator) = (created=0, tick=0)
function PSE.run!(model::GrowthCreator, status, environment, constants, context)
    if status.created < model.limit
        id = status.created + 3
        PSE.register_object!(PSE.runtime_model(context), PSE.Object(id;
            kind=:growth_unit, geometry=(cell=:initial,),
            status=(x=0.0f0, visits=0)))
        status.created += 1
    end
    status.tick = status.created
    return nothing
end

struct GrowthNumeric{T} <: AbstractLean_Growth_NumericModel
    factor::T
end
PSE.inputs_(::GrowthNumeric) = (trigger=PSE.Required(Int),)
PSE.outputs_(model::GrowthNumeric) = (x=zero(model.factor), visits=0)
function PSE.run!(model::GrowthNumeric, status, environment, constants, context)
    status.x += model.factor * status.trigger
    status.visits += 1
    return nothing
end
CR.region_effects(::Type{<:GrowthNumeric}) = :local_ports

struct GrowthCollector <: AbstractLean_Growth_CollectorModel end
PSE.inputs_(::GrowthCollector) = (signals=PSE.Required(Vector{Float32}),
    optional=PSE.Default(-1.0f0))
PSE.outputs_(::GrowthCollector) = (total=0.0f0, optional_seen=0.0f0,
    ids=PSE.ObjectId[], values=Float32[])
function PSE.run!(::GrowthCollector, status, environment, constants, context)
    bound = PSE.bound_input(context, :signals)
    status.total = sum(bound; init=0.0f0)
    status.optional_seen = status.optional
    status.ids = collect(PSE.object_ids(bound))
    status.values = collect(bound)
    return nothing
end

function growth_fixture(; native::Bool, limit=3)
    objects = PSE.Object[
        PSE.Object(0; status=(created=0, tick=0)),
        PSE.Object(1; kind=:growth_unit, geometry=(cell=:initial,), status=(x=0.0f0, visits=0)),
        PSE.Object(2; kind=:growth_unit, geometry=(cell=:initial,), status=(x=0.0f0, visits=0)),
        PSE.Object(100; status=(;)), PSE.Object(101; status=(;)),
    ]
    applications = PSE.ModelSpec[
        PSE.ModelSpec(GrowthCreator(limit); name=:create,
            on=PSE.One(id=0), every=Hour(1)),
        PSE.ModelSpec(GrowthNumeric(1.0f0); name=:produce,
            on=PSE.Many(kind=:growth_unit), every=Hour(1), inputs=(
                trigger=PSE.One(id=0, within=PSE.SceneScope(), application=:create, var=:tick),)),
        PSE.ModelSpec(CR.NativeColumnEcho{Float32}(); name=:echo,
            on=PSE.One(id=101), every=Hour(1), inputs=(
                supply=PSE.One(id=1, within=PSE.SceneScope(), application=:produce, var=:x),)),
        PSE.ModelSpec(GrowthCollector(); name=:collect,
            on=PSE.One(id=100), every=Hour(2), inputs=(
                signals=PSE.Many(kind=:growth_unit, within=PSE.SceneScope(),
                    application=:produce, var=:x),
                optional=PSE.OptionalOne(id=99, within=PSE.SceneScope(),
                    application=:produce, var=:x),)),
    ]
    return PSE.CompositeModel(objects...; applications,
        environment=(duration=Hour(1),),
        status_storage=native ? PSE.NativeColumnStorage() : nothing)
end

function _snapshot(simulation)
    topology = sort!([(id=repr(object.id.value), parent=repr(object.parent),
        kind=repr(object.kind), geometry=repr(PSE.geometry(object)))
        for object in PSE.model_objects(simulation.model)]; by=item -> item.id)
    return (scientific=XP.xp_portable_snapshot(simulation), topology)
end

"""Actual same-step newborns, live broadcast One aliases, ordered Many and cadence."""
function growth_generic_checks()
    reports = NamedTuple[]
    @testset "Incremental lean addition and independent dense recurrence" begin
        for outputs in (:none, :all)
            control = PSE.run!(growth_fixture(native=false); steps=0, outputs)
            candidate = Growth.prepare_growth(growth_fixture(native=true); steps=0, outputs)
            canonical = PSE.model_status(candidate.model, 1)
            escaped = PSE.refvalue(canonical, :x)
            echo_ref = PSE.refvalue(PSE.model_status(candidate.model, 101), :supply)
            @test escaped === echo_ref
            expected = Dict(1 => 0.0f0, 2 => 0.0f0)
            collected = copy(expected)
            for step in 1:4
                step <= 3 && (expected[step + 2] = 0.0f0)
                for id in keys(expected)
                    expected[id] += Float32(min(step, 3))
                end
                # A cadence without an explicit phase runs at the first
                # timeline sample, then holds until its next due sample.
                isodd(step) && (collected = copy(expected))
                PSE.step!(control)
                PSE.step!(candidate)
                @test isequal(_snapshot(candidate), _snapshot(control))
                for (id, value) in expected
                    @test PSE.final_state(candidate, id).x === value
                    @test PSE.final_state(candidate, id).visits == step - max(0, id - 3)
                end
                @test PSE.refvalue(canonical, :x) === escaped
                @test PSE.refvalue(PSE.model_status(candidate.model, 101), :supply) === escaped
                @test PSE.final_state(candidate, 101).observed === expected[1]
                collector = PSE.final_state(candidate, 100)
                @test collector.total === sum(values(collected))
                @test collector.optional_seen === -1.0f0
                @test Set(collector.ids) == Set(PSE.ObjectId.(collect(keys(collected))))
                @test Dict(id.value => value for (id, value) in zip(collector.ids, collector.values)) == collected
                report = Growth.growth_report(candidate)
                @test report.live_lean_batches > 0
                @test report.full_invalidations == 0
                @test report.source_facades_current
            end
            report = Growth.growth_report(candidate)
            @test report.incremental_refreshes == 3
            @test report.native_newborn_row_executions == 9
            @test report.appended_rows >= 3
            @test report.reused_numeric_groups > 0
            @test report.coalesced_batches > 0
            @test !report.disabled
            push!(reports, (; outputs, report))
        end
    end
    return (; passed=true, reports,
        oracle=:independent_dense_dictionary_and_original_per_step_full_snapshot)
end

function _mutate!(model, operation)
    if operation === :remove
        PSE.remove_object!(model, 3)
    elseif operation === :reparent
        PSE.reparent_object!(model, 1, 0)
    elseif operation === :move
        PSE.move_object!(model, 1, (cell=:moved,))
    elseif operation === :coalesced_environment
        PSE.register_object!(model, PSE.Object(20; kind=:growth_unit,
            geometry=(cell=:initial,), status=(x=0.0f0, visits=0)))
        PSE.mark_environment_binding_dirty!(model, 1)
    elseif operation === :replace_model
        model.applications[2] = PSE.ModelSpec(GrowthNumeric(2.0f0); name=:produce,
            on=PSE.Many(kind=:growth_unit), every=Hour(1), inputs=(
                trigger=PSE.One(id=0, within=PSE.SceneScope(), application=:create, var=:tick),))
        PSE._mark_bindings_dirty!(model)
    elseif operation === :consumed_refresh
        PSE.register_object!(model, PSE.Object(20; kind=:growth_unit,
            geometry=(cell=:initial,), status=(x=0.0f0, visits=0)))
        compiled = PSE.refresh_bindings!(model)
        PSE.refresh_environment_bindings!(model, compiled)
    else
        error("Unknown growth mutation gate")
    end
    return nothing
end

function growth_mutation_checks()
    reports = NamedTuple[]
    @testset "Incremental lean rejection retains original mutation semantics" begin
        for operation in (:remove, :reparent, :move, :coalesced_environment,
            :replace_model, :consumed_refresh)
            control = PSE.run!(growth_fixture(native=false); steps=1, outputs=:all)
            candidate = Growth.prepare_growth(growth_fixture(native=true); steps=1, outputs=:all)
            if operation === :consumed_refresh
                # The ordinary control performs its normal refresh barrier.
                # Only the candidate exercises caches consumed externally.
                PSE.register_object!(control.model, PSE.Object(20;
                    kind=:growth_unit, geometry=(cell=:initial,),
                    status=(x=0.0f0, visits=0)))
            else
                _mutate!(control.model, operation)
            end
            _mutate!(candidate.model, operation)
            PSE.continue!(control; steps=2)
            PSE.continue!(candidate; steps=2)
            @test isequal(_snapshot(candidate), _snapshot(control))
            report = Growth.growth_report(candidate)
            @test report.full_invalidations == 1
            @test report.live_lean_batches == 0
            @test report.disabled
            @test report.native_newborn_row_executions > 0
            push!(reports, (; operation, report))
        end
        control = PSE.run!(growth_fixture(native=false); steps=2,
            outputs=:all, performance=true)
        candidate = Growth.prepare_growth(growth_fixture(native=true); steps=2,
            outputs=:all, performance=true)
        @test isequal(_snapshot(candidate), _snapshot(control))
        @test Growth.growth_report(candidate).disabled
        @test Growth.growth_report(candidate).driver_row_executions == 0
    end
    return (; passed=true, reports,
        qualification=:unsupported_events_and_external_consumption_use_original_plan)
end

function growth_xp_checks(; steps=4)
    weather = CR._xpalm_fixture_weather(steps)
    control = PSE.run!(XP.xpalm_native_fixture(; steps, weather, native=false);
        steps=0, outputs=:all)
    candidate = Growth.prepare_growth(XP.xpalm_native_fixture(; steps, weather, native=true);
        steps=0, outputs=:all)
    initial = Set(PSE.object_ids(candidate.model))
    reports = NamedTuple[]
    @testset "Original XPalm kernels retain lean execution through real growth" begin
        @test XP.xp_semantic_digest(candidate) == XP.xp_semantic_digest(control)
        for step in 1:steps
            PSE.step!(control)
            PSE.step!(candidate)
            @test XP.xp_semantic_digest(candidate) == XP.xp_semantic_digest(control)
            report = Growth.growth_report(candidate)
            @test report.live_lean_batches > 0
            @test report.full_invalidations == 0
            @test report.source_facades_current
            push!(reports, (; step, report))
        end
        final = Growth.growth_report(candidate)
        @test final.incremental_refreshes > 0
        @test final.native_newborn_row_executions > 0
        @test final.appended_rows > 0
        @test count(id -> !(id in initial), PSE.object_ids(candidate.model)) >= 3
        @test final.driver_row_executions > 7
        # Continuing through the ordinary public API keeps the same optimized
        # representation and timeline; no separate executor repairs its state.
        @test !final.disabled
    end
    return (; passed=true, reports, report=Growth.growth_report(candidate),
        interpretation=:accelerated_growth_fixture_not_biological_validation)
end

"""The incremental driver also preserves ordinary reference ownership."""
function growth_reference_checks()
    control = PSE.run!(growth_fixture(native=false); steps=0, outputs=:all)
    candidate = Growth.prepare_growth(growth_fixture(native=false); steps=0,
        outputs=:all, state_strategy=:references)
    canonical = PSE.model_status(candidate.model, 1)
    escaped = PSE.refvalue(canonical, :x)
    @testset "Incremental lean reference-backed control" begin
        @test escaped isa Base.RefValue{Float32}
        for _ in 1:4
            PSE.step!(control)
            PSE.step!(candidate)
            @test isequal(_snapshot(candidate), _snapshot(control))
        end
        @test escaped === PSE.refvalue(PSE.model_status(candidate.model, 1), :x)
        @test PSE.final_state(candidate, 1).x === 9.0f0
        @test PSE.final_state(candidate, 3).x === 9.0f0
        @test PSE.final_state(candidate, 4).x === 8.0f0
        @test PSE.final_state(candidate, 5).x === 6.0f0
        report = Growth.growth_report(candidate)
        @test report.driver_row_executions > 0
        @test report.incremental_refreshes == 3
        @test report.live_lean_batches > 0
        @test report.native_row_executions == 0
        @test report.executed_native_column_fields == 0
        @test report.native_newborn_row_executions == 0
        @test report.live_native_rows == 0
        @test report.full_invalidations == 0
        @test report.source_facades_current
    end
    return (passed=true, report=Growth.growth_report(candidate))
end

"""Real XPalm growth without changing ordinary canonical reference storage."""
function growth_xp_reference_checks(; steps=4)
    weather = CR._xpalm_fixture_weather(steps)
    control = PSE.run!(XP.xpalm_native_fixture(; steps, weather, native=false);
        steps=0, outputs=:all)
    candidate = Growth.prepare_growth(XP.xpalm_native_fixture(; steps, weather, native=false);
        steps=0, outputs=:all, state_strategy=:references)
    initial_ids = Set(PSE.object_ids(candidate.model))
    initial_memberships = Set{Tuple{Symbol,PSE.ObjectId}}()
    for batch in candidate.execution_plan.batches
        batch isa Growth.GrowingLeanBatch || continue
        for id in batch.row_ids
            push!(initial_memberships, (batch.application.id, id))
        end
    end
    initial_numeric_rows = Growth.growth_report(candidate).initial_skipped_rich_targets
    reports = NamedTuple[]
    @testset "Original XPalm with incremental reference-backed numerical batches" begin
        @test candidate.model.status_storage === nothing
        @test initial_numeric_rows == length(initial_memberships)
        @test initial_numeric_rows > 0
        @test isequal(_snapshot(candidate), _snapshot(control))
        for step in 1:steps
            PSE.step!(control)
            PSE.step!(candidate)
            @test isequal(_snapshot(candidate), _snapshot(control))
            report = Growth.growth_report(candidate)
            @test report.live_lean_batches > 0
            @test report.full_invalidations == 0
            @test report.source_facades_current
            @test report.native_row_executions == 0
            @test report.executed_native_column_fields == 0
            @test report.native_newborn_row_executions == 0
            @test report.live_native_rows == 0
            # In this daily fixture, each initial numerical membership runs at
            # most once per base step. Check that initial objects do not gain
            # newly eligible applications, so the final excess-row count is a
            # conservative lower bound on genuine newborn driver execution.
            for batch in candidate.execution_plan.batches
                batch isa Growth.GrowingLeanBatch || continue
                for id in batch.row_ids
                    id in initial_ids || continue
                    @test (batch.application.id, id) in initial_memberships
                end
            end
            push!(reports, (; step, report))
        end
        final = Growth.growth_report(candidate)
        @test final.incremental_refreshes > 0
        @test final.driver_row_executions > initial_numeric_rows * steps
        @test count(id -> !(id in initial_ids), PSE.object_ids(candidate.model)) >= 3
        @test !final.disabled
    end
    report = Growth.growth_report(candidate)
    return (passed=true, reports, report,
        newborn_driver_lower_bound=report.driver_row_executions - initial_numeric_rows * steps,
        coverage=:daily_fixture_initial_memberships_bound,
        interpretation=:accelerated_growth_fixture_not_biological_validation)
end

function _source_fixture(native)
    return PSE.CompositeModel(
        PSE.Object(1; kind=:source, status=(value=0.0f0, visits=0)),
        PSE.Object(2; kind=:source, status=(value=0.0f0, visits=0)),
        PSE.Object(100; status=(observed=0.0f0, visits=0));
        applications=(
            PSE.ModelSpec(Main.LeanReadableSource(2.0f0); name=:source,
                on=PSE.Many(kind=:source), every=Hour(1)),
            PSE.ModelSpec(Main.LeanReadableConsumer{Float32}(); name=:consumer,
                on=PSE.One(id=100), every=Hour(1), inputs=(
                    supply=PSE.One(id=1, within=PSE.SceneScope(),
                        application=:source, var=:value),)),),
        environment=(temperature=3.0f0, duration=Hour(1)),
        status_storage=native ? PSE.NativeColumnStorage() : nothing)
end

function growth_inspection_checks()
    reports = NamedTuple[]
    @testset "Incremental growth updates readable-source facades and inspection" begin
        for outputs in (:none, :all)
            control = PSE.run!(_source_fixture(false); steps=1, outputs)
            candidate = Growth.prepare_growth(_source_fixture(true); steps=1, outputs)
            for model in (control.model, candidate.model)
                PSE.register_object!(model, PSE.Object(3; kind=:source,
                    status=(value=0.0f0, visits=0)))
            end
            PSE.step!(control)
            PSE.step!(candidate)
            @test isequal(_snapshot(candidate), _snapshot(control))
            before = Growth.growth_report(candidate)
            @test before.incremental_refreshes == 1
            @test before.native_newborn_row_executions == 1
            @test before.source_facades_current
            @test before.lazy_target_snapshots == 0
            explanation = PSE.Diagnostics.explain_execution_plan(candidate)
            @test sum(row -> row.batch_size, explanation) == 4
            @test Growth.growth_report(candidate).lazy_target_snapshots == 0
            graph = PSE.model_graph_view(candidate.compiled; level=:resolved)
            @test isempty(graph.diagnostics)
            source = PSE.Authoring.compiled_model_source(candidate;
                function_name=:growing_readable_model!)
            generated_module = Module(gensym(:GrowingReadableModel))
            Base.include_string(generated_module, source, "growing-readable-model.jl")
            generated_run = Core.eval(generated_module, :growing_readable_model!)
            Base.invokelatest(generated_run, candidate; steps=2)
            PSE.continue!(control; steps=2)
            @test isequal(_snapshot(candidate), _snapshot(control))
            @test Growth.growth_report(candidate).lazy_target_snapshots == 6
            @test Growth.growth_report(candidate).native_newborn_row_executions == 1
            PSE.step!(candidate)
            PSE.step!(control)
            @test isequal(_snapshot(candidate), _snapshot(control))
            @test Growth.growth_report(candidate).native_newborn_row_executions == 2
            @test Growth.growth_report(candidate).source_facades_current
            push!(reports, (; outputs, report=Growth.growth_report(candidate)))
        end
    end
    return (; passed=true, reports)
end

function growth_all_checks()
    return (generic=growth_generic_checks(), mutations=growth_mutation_checks(),
        xpalm=growth_xp_checks(), inspection=growth_inspection_checks(),
        reference=growth_reference_checks())
end

end # module
