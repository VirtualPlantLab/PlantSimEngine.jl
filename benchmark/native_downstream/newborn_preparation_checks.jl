module NewbornPreparationChecks

using Dates, Test, PlantSimEngine
const PSE = PlantSimEngine
const NP = Main.NewbornPreparation
const XP = Main.NativeXPDriver
const CR = Main.CompiledRegionsExperiment

export newborn_generic_checks, newborn_multirate_checks, newborn_xp_checks,
    newborn_preparation_checks

PSE.@process "preparation_creator" verbose=false
PSE.@process "preparation_source" verbose=false
PSE.@process "preparation_initial" verbose=false
PSE.@process "preparation_probe" verbose=false

struct PreparationCreator{W} <: AbstractPreparation_CreatorModel
    weather::W
    limit::Int
    mutation::Symbol
end
PSE.inputs_(::PreparationCreator) = (;)
PSE.outputs_(::PreparationCreator) = (created=0, initialized=0.0f0,
    first_sample=0.0f0, second_sample=0.0f0)
function PSE.run!(model::PreparationCreator, status, environment, constants, context)
    status.created >= model.limit && return nothing
    runtime = PSE.runtime_model(context)
    newborn = PSE.register_object!(runtime, PSE.Object(status.created + 10;
        kind=:preparation_unit, parent=0,
        status=(supply=4.0f0, mass=2.0f0, previous=2.0f0, initializer_runs=0)))
    status.initialized = PSE.run_initializer!(context, :initialize, newborn).mass
    first = only(PSE.run_call!(context, :probe; objects=newborn, publish=false))
    status.first_sample = first.status.sampled
    model.weather.T += 1.0f0
    second = only(PSE.run_call!(context, :probe; objects=newborn, publish=false))
    status.second_sample = second.status.sampled
    if model.mutation === :later_addition
        # The first newborn's membership was resolved before this second birth.
        # Its cached Many binding must miss the event mutation epoch guard.
        PSE.register_object!(runtime, PSE.Object(status.created + 100;
            kind=:preparation_unit, parent=0,
            status=(supply=8.0f0, mass=3.0f0, previous=3.0f0, initializer_runs=0)))
    elseif model.mutation === :coalesced_environment
        PSE.mark_environment_binding_dirty!(runtime, 1)
    elseif model.mutation === :movement
        PSE.move_object!(runtime, 1, (cell=:moved,))
    elseif model.mutation !== :none
        error("Unknown newborn preparation mutation $(model.mutation)")
    end
    status.created += 1
    return nothing
end

struct PreparationSource <: AbstractPreparation_SourceModel end
PSE.inputs_(::PreparationSource) = (;)
PSE.outputs_(::PreparationSource) = (supply=0.0f0, source_runs=0)
function PSE.run!(::PreparationSource, status, environment, constants, context)
    status.supply += 1.0f0
    status.source_runs += 1
    return nothing
end

struct PreparationInitial <: AbstractPreparation_InitialModel end
PSE.inputs_(::PreparationInitial) = (previous=PSE.Required(Float32),)
PSE.outputs_(::PreparationInitial) = (mass=0.0f0, initializer_runs=0)
PSE.environment_inputs_(::PreparationInitial) = (T=0.0f0,)
function PSE.run!(::PreparationInitial, status, environment, constants, context)
    status.mass = status.previous + environment.T
    status.initializer_runs += 1
    return nothing
end

struct PreparationProbe <: AbstractPreparation_ProbeModel end
PSE.inputs_(::PreparationProbe) = (signals=PSE.Required(Vector{Float32}),)
PSE.outputs_(::PreparationProbe) = (total=0.0f0, sampled=0.0f0,
    ids=PSE.ObjectId[], observed=Float32[])
PSE.environment_inputs_(::PreparationProbe) = (T=0.0f0,)
function PSE.run!(::PreparationProbe, status, environment, constants, context)
    view = PSE.bound_input(context, :signals)
    status.total = sum(view; init=0.0f0)
    status.ids = collect(PSE.object_ids(view))
    status.observed = collect(view)
    status.sampled = environment.T
    return nothing
end

function preparation_fixture(; mutation=:none, limit=2, source_every=Hour(1))
    # Status is a supported mutable singleton global environment. Every target
    # must read its current value, including repeated calls at the same time.
    weather = PSE.Status(T=10.0f0, duration=Hour(1))
    applications = (
        PSE.ModelSpec(PreparationCreator(weather, limit, mutation); name=:creator,
            on=PSE.One(id=0), every=Hour(1), calls=(
                initialize=PSE.Initializer(PSE.One(kind=:preparation_unit,
                    within=PSE.Subtree(), application=:initialize)),
                probe=PSE.Many(kind=:preparation_unit, within=PSE.Subtree(),
                    application=:probe))),
        PSE.ModelSpec(PreparationInitial(); name=:initialize,
            on=PSE.Many(kind=:preparation_unit), every=Hour(1), inputs=(
                previous=PSE.One(within=PSE.Self(), application=:initialize,
                    var=:mass, policy=PSE.PreviousTimeStep(:previous)),)),
        PSE.ModelSpec(PreparationSource(); name=:source,
            on=PSE.Many(kind=:preparation_unit), every=source_every),
        PSE.ModelSpec(PreparationProbe(); name=:probe,
            on=PSE.Many(kind=:preparation_unit), every=Hour(1), inputs=(
                signals=PSE.Many(kind=:preparation_unit, within=PSE.SceneScope(),
                    application=:source, var=:supply),)),
    )
    model = PSE.CompositeModel(PSE.Object(0), PSE.Object(1;
        kind=:preparation_unit, parent=0, geometry=(cell=:initial,),
        # Required PreviousTimeStep ports need an explicit initial status
        # value; the temporal carrier itself is not a same-step binding.
        status=(supply=7.0f0, mass=1.0f0, previous=1.0f0, initializer_runs=0));
        applications, environment=weather)
    return (; model, weather)
end

function _snapshot(simulation)
    topology = sort!([(id=repr(object.id.value), parent=repr(object.parent),
        kind=repr(object.kind), geometry=repr(PSE.geometry(object)))
        for object in PSE.model_objects(simulation.model)]; by=row -> row.id)
    return (scientific=XP.xp_portable_snapshot(simulation), topology)
end

"""Many identities, live refs, newborn PreviousTimeStep and fresh mutable samples."""
function newborn_generic_checks()
    reports = Any[]
    @testset "Event-owned newborn logical preparation promotion" begin
        for mutation in (:none, :later_addition, :coalesced_environment, :movement),
            outputs in (:none, :all)
            left = preparation_fixture(; mutation)
            right = preparation_fixture(; mutation)
            reference = PSE.run!(left.model; steps=0, outputs)
            candidate = NP.prepare_newborn(right.model; steps=0, outputs)
            ordinary_stable = PSE.model_status(left.model, 1)
            stable = PSE.model_status(right.model, 1)
            ordinary_escaped = PSE.refvalue(ordinary_stable, :supply)
            escaped = PSE.refvalue(stable, :supply)
            for step in 1:3
                previous_ordinary = PSE.model_status(left.model, 1)
                previous_candidate = PSE.model_status(right.model, 1)
                PSE.step!(reference)
                PSE.step!(candidate)
                @test isequal(_snapshot(candidate), _snapshot(reference))
                current_ordinary = PSE.model_status(left.model, 1)
                current_candidate = PSE.model_status(right.model, 1)
                # Rebinding a Many field can materialize a new immutable
                # whole Status while preserving its untouched scalar cells.
                # Match both initial and per-step wrapper identity behavior.
                @test (current_candidate === stable) ===
                    (current_ordinary === ordinary_stable)
                @test (current_candidate === previous_candidate) ===
                    (current_ordinary === previous_ordinary)
                if current_ordinary === ordinary_stable
                    @test current_candidate === stable
                end
                @test PSE.refvalue(stable, :supply) === escaped
                @test PSE.refvalue(current_candidate, :supply) === escaped
                @test PSE.refvalue(current_ordinary, :supply) === ordinary_escaped
                creator = PSE.final_state(candidate, 0)
                @test creator.second_sample === creator.first_sample + 1.0f0
                @test creator.first_sample === Float32(9 + min(step, 2))
                @test creator.second_sample === Float32(10 + min(step, 2))
                @test right.weather.T === left.weather.T
                if step <= 2
                    @test creator.initialized === Float32(11 + step)
                    probe = PSE.final_state(candidate, step + 9)
                    @test length(probe.ids) == step + 1 +
                        (mutation === :later_addition ? step - 1 : 0)
                    @test probe.total === sum(probe.observed; init=0.0f0)
                    @test PSE.ObjectId(step + 9) in probe.ids
                end
            end
            report = NP.newborn_preparation_report(candidate)
            @test report.captured_targets > 0
            @test report.captured_bindings > 0
            @test report.promotion_attempts > 0
            @test !report.cached_scientific_values
            @test !report.promoted_status_views
            @test !report.promoted_environment_bindings
            if mutation === :none
                @test report.promoted_targets > 0
                @test report.promoted_bindings > 0
            elseif mutation === :later_addition
                @test get(report.misses, :epoch_changed, 0) > 0
                @test report.promoted_bindings == 0
            else
                @test report.promoted_bindings == 0
            end
            push!(reports, (; mutation, outputs, report))
        end
    end
    return (; passed=true, reports,
        oracle=:ordinary_per_step_full_state_history_and_topology)
end

"""Faster consumer/initializer, slower producer and an escaped source mutation."""
function newborn_multirate_checks()
    left = preparation_fixture(; source_every=Hour(2))
    right = preparation_fixture(; source_every=Hour(2))
    reference = PSE.run!(left.model; steps=0, outputs=:all)
    candidate = NP.prepare_newborn(right.model; steps=0, outputs=:all)
    escaped = PSE.refvalue(PSE.model_status(right.model, 1), :supply)
    @testset "Newborn preparation preserves mixed cadence and live source refs" begin
        for step in 1:4
            PSE.step!(reference)
            PSE.step!(candidate)
            if step == 2
                escaped[] = 41.0f0
                PSE.model_status(left.model, 1).supply = 41.0f0
            end
            @test isequal(_snapshot(candidate), _snapshot(reference))
            @test PSE.refvalue(PSE.model_status(right.model, 1), :supply) === escaped
            @test PSE.final_state(candidate, 1).source_runs == cld(step, 2)
            @test escaped[] === (step == 1 ? 8.0f0 : step == 2 ? 41.0f0 : 42.0f0)
        end
        @test NP.newborn_preparation_report(candidate).promoted_bindings > 0
    end
    return (passed=true, report=NP.newborn_preparation_report(candidate),
        oracle=:original_per_step_state_history_and_independent_source_cadence)
end

"""Original XPalm storage/executor with only logical preparation reuse enabled."""
function newborn_xp_checks(; steps=4, incremental::Bool=false)
    weather = CR._xpalm_fixture_weather(steps)
    reference = PSE.run!(XP.xpalm_native_fixture(; steps, weather, native=false);
        steps=0, outputs=:all)
    model = XP.xpalm_native_fixture(; steps, weather, native=false)
    candidate = if incremental
        NP.enable_newborn_preparation!(model)
        getfield(Main, :LeanNativeGrowth).prepare_growth(model;
            steps=0, outputs=:all, state_strategy=:references)
    else
        NP.prepare_newborn(model; steps=0, outputs=:all)
    end
    initial_ids = Set(PSE.object_ids(candidate.model))
    reports = Any[]
    @testset "XPalm newborn preparation with full retained output parity" begin
        @test isequal(_snapshot(candidate), _snapshot(reference))
        for step in 1:steps
            PSE.step!(reference)
            PSE.step!(candidate)
            @test isequal(_snapshot(candidate), _snapshot(reference))
            push!(reports, (; step, report=NP.newborn_preparation_report(candidate)))
        end
        report = NP.newborn_preparation_report(candidate)
        @test report.captured_bindings > 0
        @test report.promoted_targets > 0
        @test report.promoted_bindings > 0
        @test count(id -> !(id in initial_ids), PSE.object_ids(candidate.model)) >= 3
        @test candidate.model.status_storage === nothing
        if incremental
            growth = getfield(Main, :LeanNativeGrowth).growth_report(candidate)
            @test growth.incremental_refreshes > 0
            @test growth.full_invalidations == 0
            @test growth.source_facades_current
            @test growth.driver_row_executions > growth.initial_skipped_rich_targets * steps
            @test growth.native_row_executions == 0
            @test growth.live_native_rows == 0
        end
    end
    return (; passed=true, reports, report=NP.newborn_preparation_report(candidate),
        growth=incremental ? getfield(Main, :LeanNativeGrowth).growth_report(candidate) : nothing,
        interpretation=:accelerated_growth_fixture_not_biological_validation)
end

newborn_preparation_checks() = (generic=newborn_generic_checks(),
    multirate=newborn_multirate_checks(), xp=newborn_xp_checks())

end # module
