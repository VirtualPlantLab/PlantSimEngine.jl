module CallGrowthChecks

using Dates, Test, PlantSimEngine

const PSE = PlantSimEngine
const CR = Main.CompiledRegionsExperiment
const PB = Main.NativePBDriver
const XP = Main.NativeXPDriver

export direct_public_checks, direct_transitive_checks, growth_public_checks,
    instrumentation_checks, consumed_refresh_checks, direct_active_materialization_checks

_direct_backend() = getfield(Main, :DirectCallCompiler)
_growth_backend() = getfield(Main, :LeanNativeGrowth)

function _topology(simulation)
    rows = [(id=repr(object.id.value), parent=repr(object.parent),
        name=repr(object.name), scale=object.scale, kind=object.kind,
        species=object.species) for object in PSE.model_objects(simulation.model)]
    return sort!(rows; by=row -> row.id)
end

function _same_public_state(reference, candidate; xp=false)
    left = xp ? XP.xp_portable_snapshot(reference) : CR.downstream_fingerprint(reference)
    right = xp ? XP.xp_portable_snapshot(candidate) : CR.downstream_fingerprint(candidate)
    return isequal(left, right) && isequal(_topology(reference), _topology(candidate))
end

"""
Independent small real-PB/public-API gate. Direct rows must execute before an
external mutation; escaped references remain live and ordinary continuation
must preserve all state/history through removal. Broader call APIs may use
explicit fallback, which is recorded without claiming optimized child work.
"""
function direct_public_checks(; nobjects::Int=2)
    nobjects >= 2 || throw(ArgumentError("Removal gate needs at least two objects"))
    backend = _direct_backend()
    reports = Any[]
    @testset "Direct calls preserve real PB public continuation and references" begin
        for native in (false, true)
            control_fixture = PB.pb_native_fixture(; native=false, nobjects, steps=4)
            fixture = PB.pb_native_fixture(; native, nobjects, steps=4)
            reference = PSE.run!(control_fixture.model; steps=0, outputs=:all)
            candidate = backend.prepare_direct_calls(fixture.model;
                steps=0, outputs=:all, state_strategy=native ? :native : :references)
            @test _same_public_state(reference, candidate)
            canonical = PSE.model_status(fixture.model, 1)
            reference_cell = PSE.refvalue(canonical, :Ra_SW_f)
            @test (reference_cell isa Base.RefArray) === native
            for _ in 1:2
                PSE.step!(reference)
                PSE.step!(candidate)
                @test _same_public_state(reference, candidate)
            end
            report = backend.direct_call_report(candidate)
            @test report.executed_numerical_roots > 0
            @test report.executed_numerical_calls > 0
            @test (report.executed_native_column_fields > 0) === native
            reference_cell[] = 177.0
            PSE.model_status(control_fixture.model, 1).Ra_SW_f = 177.0
            PSE.continue!(reference; steps=1)
            PSE.continue!(candidate; steps=1)
            @test _same_public_state(reference, candidate)
            PSE.remove_object!(control_fixture.model, nobjects)
            PSE.remove_object!(fixture.model, nobjects)
            PSE.continue!(reference; steps=1)
            PSE.continue!(candidate; steps=1)
            @test _same_public_state(reference, candidate)
            @test PSE.model_status(fixture.model, 1) === canonical
            @test PSE.refvalue(canonical, :Ra_SW_f) === reference_cell
            @test reference_cell[] === 177.0
            push!(reports, (; native, report=backend.direct_call_report(candidate)))
        end
    end
    semantic_cases = (
        (name=:accepted_evaluation, builder=() -> CR.gate_call_fixture()),
        (name=:stale_evaluation, builder=() -> CR.gate_call_fixture(CR.GateStaleController())),
        (name=:backend_override, builder=() -> CR.gate_call_fixture(CR.GateOverrideController())),
        (name=:selected_objects, builder=() -> CR.gate_call_fixture(PB.NativeSelectedCallController())),
        (name=:published_exception, builder=() -> CR.call_exception_fixture(; publish=true)),
        (name=:unpublished_exception, builder=() -> CR.call_exception_fixture(; publish=false)),
        (name=:many_targets, builder=() -> CR.gate_many_fixture(2)),
        (name=:empty_many_targets, builder=() -> CR.gate_many_fixture(0)),
    )
    @testset "Direct call backend retains delegated and unsupported APIs" begin
        for case in semantic_cases
            reference = PSE.run!(case.builder(); steps=0, outputs=:all)
            candidate = backend.prepare_direct_calls(PB._native_gate_copy(case.builder());
                steps=0, outputs=:all)
            for _ in 1:2
                PSE.continue!(reference; steps=1)
                PSE.continue!(candidate; steps=1)
                @test _same_public_state(reference, candidate)
            end
            push!(reports, (case=case.name,
                report=backend.direct_call_report(candidate),
                qualification=:feature_parity_optimized_or_explicit_fallback))
        end
    end
    return (; passed=true, reports,
        qualification=:real_original_PB_and_public_call_contracts_not_full_suite)
end

PSE.@process "call_growth_transitive_root" verbose=false
PSE.@process "call_growth_transitive_middle" verbose=false
PSE.@process "call_growth_transitive_leaf" verbose=false

struct TransitiveRoot <: AbstractCall_Growth_Transitive_RootModel
    publish::Bool
end
struct TransitiveMiddle <: AbstractCall_Growth_Transitive_MiddleModel end
struct TransitiveLeaf <: AbstractCall_Growth_Transitive_LeafModel
    throw_first::Bool
end
PSE.inputs_(::TransitiveRoot) = NamedTuple()
PSE.inputs_(::TransitiveMiddle) = NamedTuple()
PSE.inputs_(::TransitiveLeaf) = NamedTuple()
PSE.outputs_(::TransitiveRoot) = (root_visits=0, caught=false)
PSE.outputs_(::TransitiveMiddle) = (middle_visits=0,)
PSE.outputs_(::TransitiveLeaf) = (leaf_visits=0, value=0.0f0)
for T in (TransitiveRoot, TransitiveMiddle, TransitiveLeaf)
    @eval PB.native_call_effects(::Type{$T}) = :fixed_native_calls
end

function PSE.run!(model::TransitiveRoot, status, environment, constants, context)
    caught = false
    try
        # Intentionally do not inspect the returned collection: the direct
        # graph should remain eligible for every numerical descendant.
        PSE.run_call!(context, :middle; sampled_environment=environment,
            publish=model.publish)
    catch error
        error isa ErrorException && error.msg == "expected nested call failure" || rethrow()
        caught = true
        status.caught = true
    end
    if caught
        PSE.run_call!(context, :middle; sampled_environment=environment,
            publish=model.publish)
    end
    status.root_visits += 1
    return nothing
end
function PSE.run!(::TransitiveMiddle, status, environment, constants, context)
    status.middle_visits += 1
    PSE.run_call!(context, :leaf; sampled_environment=environment, publish=true)
    return nothing
end
function PSE.run!(model::TransitiveLeaf, status, environment, constants, context)
    status.leaf_visits += 1
    model.throw_first && status.leaf_visits == 1 &&
        throw(ErrorException("expected nested call failure"))
    status.value += 0.5f0
    return nothing
end

function _transitive_fixture(native; publish=false, throw_first=false)
    return PSE.CompositeModel(PSE.Object(:unit;
            status=(root_visits=0, caught=false, middle_visits=0,
                leaf_visits=0, value=0.0f0));
        status_storage=native ? PSE.NativeColumnStorage() : nothing,
        environment=(duration=Hour(1),), applications=(
            PSE.ModelSpec(TransitiveRoot(publish); name=:root,
                on=PSE.One(id=:unit), every=Hour(1), calls=(
                    middle=PSE.One(within=PSE.Self(), application=:middle),)),
            PSE.ModelSpec(TransitiveMiddle(); name=:middle,
                on=PSE.One(id=:unit), every=Hour(1), calls=(
                    leaf=PSE.One(within=PSE.Self(), application=:leaf),)),
            PSE.ModelSpec(TransitiveLeaf(throw_first); name=:leaf,
                on=PSE.One(id=:unit), every=Hour(1)),
        ))
end

"""Fully direct three-level graph, including transitive suppression and retry."""
function direct_transitive_checks()
    backend = _direct_backend()
    reports = Any[]
    @testset "Direct nested publication and exception cleanup" begin
        for publish in (false, true), throw_first in (false, true)
            reference = PSE.run!(_transitive_fixture(false; publish, throw_first);
                steps=0, outputs=:all)
            candidate = backend.prepare_direct_calls(
                _transitive_fixture(true; publish, throw_first); steps=0, outputs=:all)
            for _ in 1:2
                PSE.continue!(reference; steps=1)
                PSE.continue!(candidate; steps=1)
                @test _same_public_state(reference, candidate)
            end
            state = PSE.final_state(candidate, :unit)
            @test state.root_visits == 2
            @test state.caught === throw_first
            @test state.middle_visits == state.leaf_visits == (throw_first ? 3 : 2)
            @test state.value === 1.0f0
            report = backend.direct_call_report(candidate)
            @test report.executed_numerical_roots > 0
            @test report.executed_numerical_calls > 0
            @test report.executed_native_column_fields > 0
            @test report.fallback_calls == 0
            push!(reports, (; publish, throw_first, report))
        end
    end
    return (; passed=true, reports,
        qualification=:fully_direct_nested_synchronous_calls_with_all_outputs)
end

PSE.@process "call_growth_saved_root" verbose=false
PSE.@process "call_growth_saved_worker" verbose=false
struct SavedRoot <: AbstractCall_Growth_Saved_RootModel end
struct SavedWorker <: AbstractCall_Growth_Saved_WorkerModel end
PSE.inputs_(::SavedRoot) = NamedTuple()
PSE.inputs_(::SavedWorker) = NamedTuple()
PSE.outputs_(::SavedRoot) = (root_visits=0,)
PSE.outputs_(::SavedWorker) = (worker_visits=0,)
PB.native_call_effects(::Type{SavedRoot}) = :fixed_native_calls
PB.native_call_effects(::Type{SavedWorker}) = :fixed_native_calls

function PSE.run!(::SavedRoot, status, environment, constants, context)
    targets = PSE.run_call!(context, :worker; sampled_environment=environment,
        publish=false)
    # A real public return collection may escape without a RunContext escaping.
    # Its first inspection occurs during the next invocation of this worker.
    constants.saved[] = targets
    PSE.run_call!(context, :worker; sampled_environment=environment, publish=false)
    status.root_visits += 1
    return nothing
end
function PSE.run!(::SavedWorker, status, environment, constants, context)
    status.worker_visits += 1
    if constants.saved[] !== nothing
        target = only(constants.saved[])
        # Test-only observer of the core owner-lease invariant. It does not
        # choose a scientific branch or recursively invoke the current target;
        # the declared and actual execution graphs remain acyclic.
        push!(constants.observed_active, target.context_cache.in_use)
        push!(constants.snapshots, target)
    end
    PSE.run_call!(context, :leaf; sampled_environment=environment, publish=true)
    return nothing
end

function _saved_fixture(native)
    return PSE.CompositeModel(PSE.Object(:unit;
            status=(root_visits=0, worker_visits=0, leaf_visits=0, value=0.0f0));
        status_storage=native ? PSE.NativeColumnStorage() : nothing,
        environment=(duration=Hour(1),), applications=(
            PSE.ModelSpec(SavedRoot(); name=:root, on=PSE.One(id=:unit),
                every=Hour(1), calls=(worker=PSE.One(within=PSE.Self(), application=:worker),)),
            PSE.ModelSpec(SavedWorker(); name=:worker, on=PSE.One(id=:unit),
                every=Hour(1), calls=(leaf=PSE.One(within=PSE.Self(), application=:leaf),)),
            PSE.ModelSpec(TransitiveLeaf(false); name=:leaf,
                on=PSE.One(id=:unit), every=Hour(1)),
        ))
end

"""
A saved public return collection is first materialized while its worker is
running directly. The new ordinary owner must inherit the active lease, core
materialization must isolate its descendants, and finally must release it.
An external saved-target call afterwards uses the standard public API.
"""
function direct_active_materialization_checks()
    backend = _direct_backend()
    reference_constants = (saved=Ref{Any}(nothing), observed_active=Bool[], snapshots=Any[])
    candidate_constants = (saved=Ref{Any}(nothing), observed_active=Bool[], snapshots=Any[])
    reference = PSE.run!(_saved_fixture(false); steps=0, outputs=:all,
        constants=reference_constants)
    candidate = backend.prepare_direct_calls(_saved_fixture(true); steps=0, outputs=:all,
        constants=candidate_constants)
    @testset "Deferred public target materialization mirrors active owner leases" begin
        PSE.step!(reference)
        PSE.step!(candidate)
        @test _same_public_state(reference, candidate)
        @test !isempty(reference_constants.observed_active)
        @test !isempty(candidate_constants.observed_active)
        @test all(reference_constants.observed_active)
        @test all(candidate_constants.observed_active)
        @test all(target -> !target.context_cache.in_use, reference_constants.snapshots)
        @test all(target -> !target.context_cache.in_use, candidate_constants.snapshots)
        report = backend.direct_call_report(candidate)
        @test report.executed_numerical_roots > 0
        @test report.executed_numerical_calls > 0
        @test report.lazy_materializations > 0

        PSE.run_call!(last(reference_constants.snapshots); publish=true)
        PSE.run_call!(last(candidate_constants.snapshots); publish=true)
        @test _same_public_state(reference, candidate)
        PSE.step!(reference)
        PSE.step!(candidate)
        @test _same_public_state(reference, candidate)
        @test all(reference_constants.observed_active)
        @test all(candidate_constants.observed_active)
        @test all(target -> !target.context_cache.in_use, candidate_constants.snapshots)
    end
    return (; passed=true, report=backend.direct_call_report(candidate),
        qualification=:acyclic_saved_public_target_mid_invocation_materialization)
end

"""
Independent XP growth/public continuation gate. It includes an externally
consumed binding refresh after adding an object, so a cached transition flag
cannot authorize reuse based only on a now-cleared lifecycle event.
"""
function growth_public_checks(; steps::Int=4)
    steps >= 4 || throw(ArgumentError("XP growth gate needs at least four days"))
    backend = _growth_backend()
    weather = CR._xpalm_fixture_weather(steps + 2)
    reference = PSE.run!(XP.xpalm_native_fixture(; native=false, steps=steps + 2, weather);
        steps=0, outputs=:all)
    candidate = backend.prepare_growth(
        XP.xpalm_native_fixture(; native=true, steps=steps + 2, weather);
        steps=0, outputs=:all)
    initial_ids = collect(PSE.object_ids(candidate.model))
    reports = Any[]
    @testset "Incremental lean growth preserves public XP state, topology and history" begin
        @test _same_public_state(reference, candidate; xp=true)
        for _ in 1:steps
            PSE.step!(reference)
            PSE.step!(candidate)
            @test _same_public_state(reference, candidate; xp=true)
        end
        report = backend.growth_report(candidate)
        @test report.native_newborn_row_executions > 0
        @test report.incremental_refreshes > 0
        @test length(PSE.object_ids(candidate.model)) > length(initial_ids)
        push!(reports, (case=:xp_growth, report))

        # The synthetic unrelated object changes registry membership without
        # introducing a scientific XP model target. Consume semantic binding
        # work externally before public continuation, exactly as user code may.
        for simulation in (reference, candidate)
            PSE.register_object!(simulation.model,
                PSE.Object(:external_probe; status=(sentinel=1.0f0,)))
            PSE.refresh_bindings!(simulation.model)
            PSE.refresh_environment_bindings!(simulation.model)
        end
        PSE.continue!(reference; steps=1)
        PSE.continue!(candidate; steps=1)
        @test _same_public_state(reference, candidate; xp=true)
        @test PSE.final_state(candidate, :external_probe).sentinel === 1.0f0
        push!(reports, (case=:externally_consumed_refresh,
            report=backend.growth_report(candidate)))
        PSE.continue!(reference; steps=1)
        PSE.continue!(candidate; steps=1)
        @test _same_public_state(reference, candidate; xp=true)
    end
    return (; passed=true, reports,
        qualification=:original_XP_growth_full_history_topology_and_public_continuation)
end

PSE.@process "call_growth_consumed_signal" verbose=false
PSE.@process "call_growth_consumed_sum" verbose=false
struct ConsumedSignal{T} <: AbstractCall_Growth_Consumed_SignalModel
    increment::T
end
struct ConsumedSum <: AbstractCall_Growth_Consumed_SumModel end
PSE.inputs_(::ConsumedSignal) = NamedTuple()
PSE.outputs_(model::ConsumedSignal) = (signal=zero(model.increment), visits=0)
function PSE.run!(model::ConsumedSignal, status, environment, constants, context)
    status.signal += model.increment
    status.visits += 1
    return nothing
end
CR.region_effects(::Type{<:ConsumedSignal}) = :local_ports
PB.native_call_effects(::Type{<:ConsumedSignal}) = :fixed_native_calls
PSE.inputs_(::ConsumedSum) = (signals=PSE.Required(Vector{Float32}),)
PSE.outputs_(::ConsumedSum) = (total=0.0f0,
    seen_ids=PSE.ObjectId[], seen_values=Float32[])
function PSE.run!(::ConsumedSum, status, environment, constants, context)
    signals = PSE.bound_input(context, :signals)
    status.total = sum(signals; init=0.0f0)
    status.seen_ids = collect(PSE.object_ids(signals))
    status.seen_values = collect(signals)
    return nothing
end

function _consumed_fixture(native)
    return PSE.CompositeModel(
        PSE.Object(1; kind=:unit, status=(signal=0.0f0, visits=0)),
        PSE.Object(2; kind=:unit, status=(signal=0.0f0, visits=0)),
        PSE.Object(:sum; status=(total=0.0f0,
            seen_ids=PSE.ObjectId[], seen_values=Float32[]));
        status_storage=native ? PSE.NativeColumnStorage() : nothing,
        environment=(duration=Hour(1),), applications=(
            PSE.ModelSpec(ConsumedSignal(1.0f0); name=:signal,
                on=PSE.Many(kind=:unit), every=Hour(1)),
            PSE.ModelSpec(ConsumedSum(); name=:sum, on=PSE.One(id=:sum),
                every=Hour(1), inputs=(signals=PSE.Many(kind=:unit,
                    within=PSE.SceneScope(), application=:signal, var=:signal),)),
        ))
end

"""
An independent output-retention oracle for externally consumed refreshes.
Only the candidate consumes its event: the ordinary control follows normal
unconsumed addition. The expected newborn value, aligned Many IDs and public
materialized output rows are checked explicitly, not just final-state parity.
"""
function consumed_refresh_checks()
    reports = Any[]
    @testset "Consumed external refresh retains newborn streams and output requests" begin
        for strategy in (:direct_calls, :incremental_growth), output_mode in (:all, :request)
            backend = strategy === :direct_calls ? _direct_backend() : _growth_backend()
            prepare = strategy === :direct_calls ?
                backend.prepare_direct_calls : backend.prepare_growth
            outputs = output_mode === :all ? :all : PSE.OutputRequest(
                PSE.Many(kind=:unit, within=PSE.SceneScope()), :signal;
                name=:unit_signals, application=:signal, clock=Hour(1))
            reference = PSE.run!(_consumed_fixture(false); steps=0, outputs)
            candidate = prepare(_consumed_fixture(true); steps=0, outputs)
            PSE.continue!(reference; steps=1)
            PSE.continue!(candidate; steps=1)
            @test _same_public_state(reference, candidate)
            before = strategy === :direct_calls ? backend.direct_call_report(candidate) :
                backend.growth_report(candidate)
            @test (strategy === :direct_calls ? before.executed_numerical_roots :
                before.driver_row_executions) > 0
            for simulation in (reference, candidate)
                PSE.register_object!(simulation.model, PSE.Object(3; kind=:unit,
                    status=(signal=10.0f0, visits=0)))
            end
            # Exercise the lost-delta path only on the alternative executor.
            PSE.refresh_bindings!(candidate.model)
            PSE.refresh_environment_bindings!(candidate.model)
            PSE.continue!(reference; steps=1)
            PSE.continue!(candidate; steps=1)
            @test _same_public_state(reference, candidate)
            newborn = PSE.final_state(candidate, 3)
            @test newborn.signal === 11.0f0
            @test newborn.visits == 1
            reduction = PSE.final_state(candidate, :sum)
            @test reduction.total === 15.0f0
            @test Set(reduction.seen_ids) == Set(PSE.ObjectId.((1, 2, 3)))
            @test Dict(zip(reduction.seen_ids, reduction.seen_values)) ==
                Dict(PSE.ObjectId(1) => 2.0f0, PSE.ObjectId(2) => 2.0f0,
                    PSE.ObjectId(3) => 11.0f0)
            @test isequal(PSE.collect_outputs(candidate; sink=nothing),
                PSE.collect_outputs(reference; sink=nothing))
            PSE.continue!(reference; steps=1)
            PSE.continue!(candidate; steps=1)
            @test _same_public_state(reference, candidate)
            @test PSE.final_state(candidate, 3).signal === 12.0f0
            push!(reports, (; strategy, output_mode,
                report=strategy === :direct_calls ? backend.direct_call_report(candidate) :
                    backend.growth_report(candidate)))
        end
    end
    return (; passed=true, reports,
        qualification=:newborn_streams_requests_and_aligned_many_after_lost_delta)
end

"""Instrumentation retains the ordinary executor and never claims fast work."""
function instrumentation_checks()
    direct, growth = _direct_backend(), _growth_backend()
    @testset "Opt-in call/growth prototypes preserve instrumented ordinary execution" begin
        reference_fixture = PB.pb_native_fixture(; native=false, nobjects=2, steps=2)
        fixture = PB.pb_native_fixture(; native=true, nobjects=2, steps=2)
        reference = PSE.run!(reference_fixture.model; steps=2, outputs=:all, performance=true)
        candidate = direct.prepare_direct_calls(fixture.model;
            steps=2, outputs=:all, performance=true)
        @test !isnothing(candidate.performance)
        @test _same_public_state(reference, candidate)
        @test direct.direct_call_report(candidate).executed_numerical_roots == 0

        weather = CR._xpalm_fixture_weather(4)
        reference = PSE.run!(XP.xpalm_native_fixture(; native=false, steps=4, weather);
            steps=4, outputs=:all, performance=true)
        candidate = growth.prepare_growth(
            XP.xpalm_native_fixture(; native=true, steps=4, weather);
            steps=4, outputs=:all, performance=true)
        @test !isnothing(candidate.performance)
        @test _same_public_state(reference, candidate; xp=true)
        @test growth.growth_report(candidate).driver_row_executions == 0
    end
    return (; passed=true, qualification=:ordinary_instrumentation_fallback)
end

end # module
