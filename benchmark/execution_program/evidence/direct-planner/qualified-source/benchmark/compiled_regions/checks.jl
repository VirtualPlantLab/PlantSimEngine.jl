using Test

const BACKEND_VARIANTS = (:executor, :regions, :calls, :combined)

function prepare_backend(simulation, variant::Symbol; compact::Bool=true)
    variant in BACKEND_VARIANTS || throw(ArgumentError("Unknown backend $(variant)"))
    variant === :executor && return nothing
    return compile_regions(simulation;
        regions=variant in (:regions, :combined),
        resolved_calls=variant in (:calls, :combined),
        compact=compact && variant in (:regions, :combined))
end

function advance_backend!(simulation, program; steps::Int)
    isnothing(program) ? PSE.continue!(simulation; steps) : advance_regions!(program; steps)
    return simulation
end

_report_property(report, name, default) = hasproperty(report, name) ? getproperty(report, name) : default

function selected_region_count(report)
    if hasproperty(report, :region_applications)
        value = report.region_applications
        return value isa Integer ? value : length(value)
    end
    hasproperty(report, :selected_applications) && return length(report.selected_applications)
    error("Region report must expose actual selected applications")
end

function call_report_metric(report, name::Symbol)
    hasproperty(report, name) && return getproperty(report, name)
    if hasproperty(report, :resolved_calls)
        nested = report.resolved_calls
        hasproperty(nested, name) && return getproperty(nested, name)
        nested isa Union{Tuple,AbstractVector} &&
            return sum(getproperty(item, name) for item in nested; init=0)
    end
    error("Resolved-call report must expose $(name)")
end

function fast_call_count(report)
    hasproperty(report, :call_fast_hits) && return report.call_fast_hits
    if hasproperty(report, :resolved_calls)
        calls = report.resolved_calls
        hasproperty(calls, :fast_calls) && return calls.fast_calls
        calls isa Union{Tuple,AbstractVector} && return sum(x.fast_calls for x in calls; init=0)
    end
    error("Region report must expose actual resolved-call fast hits")
end

function assert_downstream_selection(kind, variant, report; required=true)
    required || return nothing
    if kind === :plantbiophysics && variant in (:calls, :combined)
        @test fast_call_count(report) > 0
    elseif kind === :xpalm && variant in (:regions, :combined)
        @test selected_region_count(report) > 0
    end
    return nothing
end

"""Exact downstream gate; mandatory growth/selection assertions prevent no-op wins."""
function check_downstream_fixture(fixture; variants=(:regions, :calls, :combined),
    outputs=:all, require_selection::Bool=true, compact::Bool=true)
    reference_model = fixture.builder()
    initial_ids = collect(PSE.object_ids(reference_model))
    reference = PSE.run!(reference_model; steps=fixture.steps, outputs)
    expected = downstream_fingerprint(reference)
    expected_work = downstream_work_report(reference, initial_ids)
    if fixture.kind === :xpalm
        @test !isempty(expected_work.added_ids)
        @test length(expected_work.added_ids) >= 3
    else
        @test isempty(expected_work.added_ids)
        @test expected_work.objects == fixture.metadata.nobjects
    end
    reports = NamedTuple[]
    for variant in variants
        model = fixture.builder()
        @test collect(PSE.object_ids(model)) == initial_ids
        simulation = PSE.run!(model; steps=0, outputs)
        program = prepare_backend(simulation, variant; compact)
        advance_backend!(simulation, program; steps=fixture.steps)
        observed = downstream_fingerprint(simulation)
        @test isequal(observed.states, expected.states)
        @test isequal(observed.histories, expected.histories)
        @test observed.step == expected.step
        work = downstream_work_report(simulation, initial_ids)
        @test work == expected_work
        report = region_report(program)
        assert_downstream_selection(fixture.kind, variant, report; required=require_selection)
        push!(reports, (; variant, report, work))
    end
    return (; package=fixture.kind, output_policy=outputs,
        metadata=fixture.metadata, reference_work=expected_work, reports)
end

"""Start with a few organs/steps; expand only after these cases pass."""
function run_downstream_checks(; pb_objects=4, pb_steps=2, xp_steps=4,
    variants=(:regions, :calls, :combined), output_modes=(:none, :all),
    require_selection=true, compact=true)
    results = NamedTuple[]
    @testset "real downstream compiled regions and calls" begin
        fixtures = (downstream_fixture(:plantbiophysics; nobjects=pb_objects, steps=pb_steps),
            downstream_fixture(:xpalm; steps=xp_steps))
        for fixture in fixtures, outputs in output_modes
            push!(results, check_downstream_fixture(fixture; variants, outputs,
                require_selection, compact))
        end
    end
    return (; cases=length(results), results)
end

"""Ordinary public continue! must remain correct after backend installation."""
function check_downstream_continuation(; kind=:xpalm, steps=4, nobjects=4,
    variant=:combined, compact=true)
    fixture = downstream_fixture(kind; steps, nobjects)
    reference = PSE.run!(fixture.builder(); steps=0, outputs=:all)
    simulation = PSE.run!(fixture.builder(); steps=0, outputs=:all)
    program = prepare_backend(simulation, variant; compact)
    @testset "compiled/public continuation interoperation" begin
        advance_regions!(program; steps=1)
        PSE.continue!(reference; steps=1)
        @test isequal(downstream_fingerprint(simulation), downstream_fingerprint(reference))
        PSE.continue!(simulation; steps=1)
        PSE.continue!(reference; steps=1)
        @test isequal(downstream_fingerprint(simulation), downstream_fingerprint(reference))
        if steps > 2
            advance_regions!(program; steps=steps - 2)
            PSE.continue!(reference; steps=steps - 2)
        end
        @test isequal(downstream_fingerprint(simulation), downstream_fingerprint(reference))
    end
    return (; kind, variant, report=region_report(program))
end

# A generic mutable sampled row exercises freshness, unpublished trials,
# accepted evaluations, direct publication and stale-token rejection. Its
# fixed call graph permits resolved calls; evaluation machinery may explicitly
# take the normal feature path and must still preserve its journal semantics.
PSE.@process "region_gate_call_worker" verbose=false
PSE.@process "region_gate_call_controller" verbose=false
mutable struct GateSampledRow
    driver::Float64
end
struct GateCallWorker <: AbstractRegion_Gate_Call_WorkerModel end
struct GateCallController <: AbstractRegion_Gate_Call_ControllerModel end
PSE.inputs_(::GateCallWorker) = NamedTuple()
PSE.environment_inputs_(::GateCallWorker) = (driver=1.0,)
PSE.outputs_(::GateCallWorker) = (value=0.0, visits=0)
function PSE.run!(::GateCallWorker, status, environment, constants, context)
    status.value = environment.driver
    status.visits += 1
    return nothing
end
PSE.inputs_(::GateCallController) = NamedTuple()
PSE.outputs_(::GateCallController) =
    (trial=0.0, accepted=0.0, published=0.0, visits=0)
function PSE.run!(::GateCallController, status, environment, constants, context)
    row = GateSampledRow(2.0)
    trial = PSE.run_call!(context, :worker; sampled_environment=row, publish=false)
    status.trial = only(trial).status.value
    row.driver = 3.0
    evaluation = PSE.evaluate_call!(context, :worker; sampled_environment=row)
    status.accepted = only(PSE.call_targets(evaluation)).status.value
    PSE.accept_call!(evaluation)
    row.driver = 4.0
    published = PSE.run_call!(context, :worker; sampled_environment=row, publish=true)
    status.published = only(published).status.value
    status.visits += 1
    return nothing
end
resolved_call_effects(::Type{GateCallController}) = :stable_calls
resolved_call_effects(::Type{GateCallWorker}) = :stable_calls

PSE.@process "region_gate_stale_controller" verbose=false
PSE.@process "region_gate_override_controller" verbose=false
struct GateStaleController <: AbstractRegion_Gate_Stale_ControllerModel end
struct GateOverrideController <: AbstractRegion_Gate_Override_ControllerModel end
PSE.inputs_(::GateStaleController) = NamedTuple()
PSE.outputs_(::GateStaleController) = (stale_rejected=false, observed=0.0)
function PSE.run!(::GateStaleController, status, environment, constants, context)
    evaluation = PSE.evaluate_call!(context, :worker;
        sampled_environment=GateSampledRow(2.0))
    PSE.run_call!(context, :worker;
        sampled_environment=GateSampledRow(3.0), publish=false)
    try
        PSE.accept_call!(evaluation)
    catch
        status.stale_rejected = true
    end
    targets = PSE.run_call!(context, :worker;
        sampled_environment=GateSampledRow(4.0), publish=true)
    status.observed = only(targets).status.value
    return nothing
end
PSE.inputs_(::GateOverrideController) = NamedTuple()
PSE.outputs_(::GateOverrideController) = (observed=0.0,)
function PSE.run!(::GateOverrideController, status, environment, constants, context)
    targets = PSE.run_call!(context, :worker;
        environment=(driver=7.0, duration=Hour(1)), publish=true)
    status.observed = only(targets).status.value
    return nothing
end
resolved_call_effects(::Type{GateStaleController}) = :stable_calls
resolved_call_effects(::Type{GateOverrideController}) = :stable_calls

PSE.@process "region_gate_many_controller" verbose=false
struct GateManyController <: AbstractRegion_Gate_Many_ControllerModel end
PSE.inputs_(::GateManyController) = NamedTuple()
PSE.outputs_(::GateManyController) = (target_count=0, absent_count=-1, observed=0.0)
function PSE.run!(::GateManyController, status, environment, constants, context)
    targets = PSE.run_call!(context, :workers;
        sampled_environment=GateSampledRow(2.0), publish=true)
    status.target_count = length(targets)
    status.observed = sum(target.status.value for target in targets; init=0.0)
    status.absent_count = length(PSE.run_call!(context, :absent;
        sampled_environment=GateSampledRow(3.0), publish=true))
    return nothing
end
resolved_call_effects(::Type{GateManyController}) = :stable_calls

function gate_many_fixture(nworkers::Int)
    objects = [PSE.Object(Symbol(:worker_, index); kind=:call_worker)
        for index in 1:nworkers]
    return PSE.CompositeModel(PSE.Object(:owner), objects...;
        applications=(
            PSE.ModelSpec(GateManyController(); name=:gate_controller,
                on=PSE.One(id=:owner), every=Hour(1), calls=(
                    workers=PSE.Many(kind=:call_worker, within=PSE.SceneScope(),
                        application=:gate_worker),
                    absent=PSE.OptionalOne(id=:absent, within=PSE.SceneScope(),
                        application=:gate_worker),)),
            PSE.ModelSpec(GateCallWorker(); name=:gate_worker,
                on=PSE.Many(kind=:call_worker), every=Hour(1)),
        ), environment=(driver=1.0, duration=Hour(1)))
end

function gate_call_fixture(controller=GateCallController())
    return PSE.CompositeModel(PSE.Object(:owner), PSE.Object(:worker);
        applications=(
            PSE.ModelSpec(controller; name=:gate_controller,
                on=PSE.One(id=:owner), every=Hour(1),
                calls=(worker=PSE.One(id=:worker, within=PSE.SceneScope(),
                    application=:gate_worker),)),
            PSE.ModelSpec(GateCallWorker(); name=:gate_worker,
                on=PSE.One(id=:worker), every=Hour(1)),
        ), environment=(driver=1.0, duration=Hour(1)))
end

function run_call_contract_checks(; variants=(:calls, :combined), steps=3)
    reports = NamedTuple[]
    @testset "resolved calls mutable rows and publication" begin
        reference = PSE.run!(gate_call_fixture(); steps, outputs=:all)
        expected = downstream_fingerprint(reference)
        for variant in variants
            simulation = PSE.run!(gate_call_fixture(); steps=0, outputs=:all)
            program = prepare_backend(simulation, variant)
            advance_regions!(program; steps)
            @test isequal(downstream_fingerprint(simulation), expected)
            @test PSE.final_state(simulation, :owner).trial == 2.0
            @test PSE.final_state(simulation, :owner).accepted == 3.0
            @test PSE.final_state(simulation, :owner).published == 4.0
            @test PSE.final_state(simulation, :worker).visits == 3steps
            report = region_report(program)
            @test fast_call_count(report) > 0
            push!(reports, (; variant, report))
        end
        for (name, controller, expected_value) in (
            (:stale_acceptance, GateStaleController(), 4.0),
            (:backend_override, GateOverrideController(), 7.0),
        ), variant in variants
            reference = PSE.run!(gate_call_fixture(controller); steps=1, outputs=:all)
            simulation = PSE.run!(gate_call_fixture(controller); steps=0, outputs=:all)
            program = prepare_backend(simulation, variant)
            advance_regions!(program; steps=1)
            @test isequal(downstream_fingerprint(simulation), downstream_fingerprint(reference))
            @test PSE.final_state(simulation, :owner).observed == expected_value
            report = region_report(program)
            if name === :stale_acceptance
                @test PSE.final_state(simulation, :owner).stale_rejected
                @test fast_call_count(report) > 0
            else
                @test call_report_metric(report, :environment_fallbacks) > 0
            end
            push!(reports, (; variant, case=name, report))
        end
        for nworkers in (0, 1, 3), variant in variants
            reference = PSE.run!(gate_many_fixture(nworkers); steps=2, outputs=:all)
            simulation = PSE.run!(gate_many_fixture(nworkers); steps=0, outputs=:all)
            program = prepare_backend(simulation, variant)
            advance_regions!(program; steps=2)
            @test isequal(downstream_fingerprint(simulation), downstream_fingerprint(reference))
            state = PSE.final_state(simulation, :owner)
            @test state.target_count == nworkers
            @test state.absent_count == 0
            @test state.observed == 2.0nworkers
            report = region_report(program)
            nworkers > 0 && (@test fast_call_count(report) > 0)
            push!(reports, (; variant, case=:many_optional, nworkers, report))
        end
    end
    return (; cases=length(reports), reports)
end

function run_region_barrier_checks(; variants=(:regions, :combined), compact=true)
    cases = (
        (name=:cross_object_reduce, builder=GP.reduction_fixture),
        (name=:same_step_growth, builder=GP.growth_fixture),
        (name=:previous_step, builder=GP.temporal_fixture),
        (name=:distributed_outputs, builder=GP.distributed_fixture),
        (name=:intentional_updates, builder=GP.updates_fixture),
    )
    reports = NamedTuple[]
    @testset "compiled region barriers" begin
        for case in cases, variant in variants
            reference = PSE.run!(case.builder(); steps=4, outputs=:all)
            simulation = PSE.run!(case.builder(); steps=0, outputs=:all)
            program = prepare_backend(simulation, variant; compact)
            advance_regions!(program; steps=4)
            @test isequal(downstream_fingerprint(simulation), downstream_fingerprint(reference))
            report = region_report(program)
            push!(reports, (; case=case.name, variant, report))
        end
    end
    return (; cases=length(reports), reports)
end
