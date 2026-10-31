module PlanViewReuseChecks

using Dates, Test, PlantSimEngine
const PSE = PlantSimEngine
const Reuse = Main.PlanViewReuse
const PB = Main.NativePBDriver
const XP = Main.NativeXPDriver
const CR = Main.CompiledRegionsExperiment

export plan_view_reuse_pb_checks, plan_view_reuse_xp_checks,
    plan_view_recipe_schema_checks, plan_view_temporal_private_checks,
    plan_view_reuse_checks

function plan_view_reuse_pb_checks(; nobjects=2, steps=2)
    reports = Any[]
    @testset "Per-application plain view recipes preserve original PB state" begin
        for outputs in (:none, :all), options in (
            (recipes=true, views=true), (recipes=true, views=false),
            (recipes=false, views=true))
            reference = PSE.run!(PB.pb_native_fixture(; native=false, nobjects, steps).model;
                steps=0, outputs)
            fixture = PB.pb_native_fixture(; native=false, nobjects, steps)
            candidate = Reuse.prepare_reuse(fixture.model; steps=0, outputs, options...)
            ordinary_status = PSE.model_status(reference.model, 1)
            candidate_status = PSE.model_status(candidate.model, 1)
            ordinary_cell = PSE.refvalue(ordinary_status, :Ra_SW_f)
            candidate_cell = PSE.refvalue(candidate_status, :Ra_SW_f)
            @test isequal(CR.portable_downstream_snapshot(candidate),
                CR.portable_downstream_snapshot(reference))
            for _ in 1:steps
                PSE.step!(reference); PSE.step!(candidate)
                @test isequal(CR.portable_downstream_snapshot(candidate),
                    CR.portable_downstream_snapshot(reference))
                @test (PSE.model_status(candidate.model, 1) === candidate_status) ==
                    (PSE.model_status(reference.model, 1) === ordinary_status)
                @test PSE.refvalue(PSE.model_status(candidate.model, 1), :Ra_SW_f) === candidate_cell
                @test PSE.refvalue(PSE.model_status(reference.model, 1), :Ra_SW_f) === ordinary_cell
            end
            report = Reuse.plan_view_reuse_report(candidate)
            if options.recipes
                @test report.recipe_hits > 0
                @test report.recipe_view_assemblies > report.recipe_builds
            else
                @test report.recipe_hits == 0
                @test report.ordinary_compiler_calls > 0
            end
            @test !report.cached_scientific_values
            @test !report.cached_environment_samples
            push!(reports, (; outputs, options, report))
        end
    end
    return (; passed=true, reports)
end

function plan_view_reuse_xp_checks(; steps=4)
    weather = CR._xpalm_fixture_weather(steps)
    reference = PSE.run!(XP.xpalm_native_fixture(; native=false, steps, weather);
        steps=0, outputs=:all)
    candidate = Reuse.prepare_reuse(
        XP.xpalm_native_fixture(; native=false, steps, weather);
        steps=0, outputs=:all)
    initial_ids = Set(PSE.object_ids(candidate.model))
    @testset "Plain view recipe reuse preserves four-day XPalm growth" begin
        @test isequal(XP.xp_portable_snapshot(candidate), XP.xp_portable_snapshot(reference))
        for _ in 1:steps
            PSE.step!(reference); PSE.step!(candidate)
            @test isequal(XP.xp_portable_snapshot(candidate), XP.xp_portable_snapshot(reference))
            @test [(object.id, object.parent) for object in PSE.model_objects(candidate.model)] ==
                [(object.id, object.parent) for object in PSE.model_objects(reference.model)]
        end
        report = Reuse.plan_view_reuse_report(candidate)
        @test report.recipe_hits > 0
        @test report.recipe_view_assemblies > report.recipe_builds
        @test report.ordinary_compiler_calls > 0 # temporal/private interfaces remain ordinary
        @test count(id -> !(id in initial_ids), PSE.object_ids(candidate.model)) >= 3
        return (; passed=true, report, steps,
            objects=length(PSE.object_ids(candidate.model)),
            added_objects=count(id -> !(id in initial_ids), PSE.object_ids(candidate.model)))
    end
end

PSE.@process "view_recipe_source" verbose=false
PSE.@process "view_recipe_reader" verbose=false
struct RecipeSource{T} <: AbstractView_Recipe_SourceModel
    port::Symbol
    value::T
    width::Int
end
PSE.inputs_(::RecipeSource) = (;)
PSE.outputs_(model::RecipeSource) = NamedTuple{(model.port, Symbol(model.port, :_payload))}(
    (zero(model.value), zeros(typeof(model.value), model.width)))
function PSE.run!(model::RecipeSource, status, environment, constants, context)
    setproperty!(status, model.port, model.value)
    fill!(getproperty(status, Symbol(model.port, :_payload)), model.value)
    return nothing
end

struct RecipeReader{T} <: AbstractView_Recipe_ReaderModel
    input::Symbol
    output::Symbol
    initial::T
end
PSE.inputs_(model::RecipeReader{T}) where {T} =
    NamedTuple{(model.input,)}((PSE.Required(T),))
PSE.outputs_(model::RecipeReader) = NamedTuple{(model.output,)}((model.initial,))
function PSE.run!(model::RecipeReader, status, environment, constants, context)
    setproperty!(status, model.output, getproperty(status, model.input) + one(model.initial))
    return nothing
end

function _schema_fixture()
    applications = (
        PSE.ModelSpec(RecipeSource(:signal_a, 2.0f0, 2); name=:source_a,
            on=PSE.Many(kind=:kind_a), every=Hour(1)),
        PSE.ModelSpec(RecipeReader(:signal_a, :seen_a, 0.0f0); name=:reader_a,
            on=PSE.Many(kind=:kind_a), every=Hour(1), inputs=(
                signal_a=PSE.One(within=PSE.Self(), application=:source_a),)),
        PSE.ModelSpec(RecipeSource(:signal_b, 4.0f0, 5); name=:source_b,
            on=PSE.Many(kind=:kind_b), every=Hour(1)),
        PSE.ModelSpec(RecipeReader(:signal_b, :seen_b, 0.0f0); name=:reader_b,
            on=PSE.Many(kind=:kind_b), every=Hour(1), inputs=(
                signal_b=PSE.One(within=PSE.Self(), application=:source_b),)),
    )
    return PSE.CompositeModel(
        PSE.Object(:a1; kind=:kind_a), PSE.Object(:a2; kind=:kind_a),
        PSE.Object(:b1; kind=:kind_b), PSE.Object(:b2; kind=:kind_b);
        applications, environment=(duration=Hour(1),))
end

function plan_view_recipe_schema_checks()
    reference = PSE.run!(_schema_fixture(); steps=0, outputs=:all)
    candidate = Reuse.prepare_reuse(_schema_fixture(); steps=0, outputs=:all)
    @testset "Recipe cache preserves parameter-dependent ports and mutable defaults" begin
        for _ in 1:2
            PSE.step!(reference); PSE.step!(candidate)
            @test isequal(CR.portable_downstream_snapshot(candidate),
                CR.portable_downstream_snapshot(reference))
        end
        @test PSE.model_status(candidate.model, :a1).seen_a === 3.0f0
        @test PSE.model_status(candidate.model, :b1).seen_b === 5.0f0
        @test length(PSE.model_status(candidate.model, :a1).signal_a_payload) == 2
        @test length(PSE.model_status(candidate.model, :b1).signal_b_payload) == 5
        @test PSE.model_status(candidate.model, :a1).signal_a_payload !==
            PSE.model_status(candidate.model, :a2).signal_a_payload
        @test PSE.model_status(candidate.model, :b1).signal_b_payload !==
            PSE.model_status(candidate.model, :b2).signal_b_payload
        @test Reuse.plan_view_reuse_report(candidate).recipe_entries == 4
        @test Reuse.plan_view_reuse_report(candidate).recipe_hits >= 4
    end
    return (; passed=true, report=Reuse.plan_view_reuse_report(candidate))
end

function _temporal_fixture()
    return PSE.CompositeModel(PSE.Object(0; status=(sentinel=0,)),
        PSE.Object(1; kind=:sample, parent=0, status=(lag=0.0f0,));
        applications=(
            PSE.ModelSpec(RecipeSource(:signal, 2.0f0, 2); name=:source,
                on=PSE.Many(kind=:sample), every=Hour(1)),
            PSE.ModelSpec(RecipeReader(:lag, :seen, 0.0f0); name=:reader,
                on=PSE.Many(kind=:sample), every=Hour(1),
                inputs=(lag=PSE.One(within=PSE.Self(), application=:source,
                    var=:signal, policy=PSE.PreviousTimeStep(:lag)),),
                output_routing=(seen=:stream_only,)),
        ), environment=(duration=Hour(1),))
end

function plan_view_temporal_private_checks()
    reference = PSE.run!(_temporal_fixture(); steps=0, outputs=:all)
    candidate = Reuse.prepare_reuse(_temporal_fixture(); steps=0, outputs=:all)
    @testset "Temporal private cells and growth keep ordinary preparation" begin
        for step in 1:3
            if step == 2
                for simulation in (reference, candidate)
                    PSE.register_object!(simulation.model, PSE.Object(2;
                        kind=:sample, parent=0, status=(lag=0.0f0,)))
                end
            end
            PSE.step!(reference); PSE.step!(candidate)
            @test isequal(CR.portable_downstream_snapshot(candidate),
                CR.portable_downstream_snapshot(reference))
        end
        report = Reuse.plan_view_reuse_report(candidate)
        @test report.ordinary_compiler_calls > 0
        @test get(report.fallback_reasons, :output_routing_boundary, 0) > 0
        for id in (1, 2)
            @test !hasproperty(PSE.model_status(candidate.model, id), :seen)
            @test candidate.compiled.status_views_by_target[(:reader, PSE.ObjectId(id))].status !==
                PSE.model_status(candidate.model, id)
        end
    end
    return (; passed=true, report=Reuse.plan_view_reuse_report(candidate))
end

plan_view_reuse_checks() = (pb=plan_view_reuse_pb_checks(),
    schemas=plan_view_recipe_schema_checks(), temporal_private=plan_view_temporal_private_checks(),
    xp=plan_view_reuse_xp_checks())

end # module
