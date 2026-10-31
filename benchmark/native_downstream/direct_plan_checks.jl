module DirectPlanChecks

using Dates, Test, PlantSimEngine
const PSE = PlantSimEngine
const Selected = Main.DirectPlanConstruction
const Native = Main.NativePBDriver
const Shared = Main.SharedCallProgram
const Tight = Main.TightCallProgram
const CR = Main.CompiledRegionsExperiment

export selected_pb_checks, selected_exception_checks, selected_retirement_checks,
    selected_partial_exception_checks, selected_public_fallback_checks,
    selected_mixed_union_rejection_check, selected_plan_checks

Base.@nospecializeinfer @noinline function _prepare(model; bounded=false, reuse=false, kwargs...)
    @nospecialize model
    if bounded
        Base.invokelatest(getfield(Main, :BoundedPreparation).enable_bounded_preparation!, model)
    end
    if reuse
        Base.invokelatest(getfield(Main, :PlanViewReuse).enable_plan_view_reuse!, model)
    end
    return Base.invokelatest(Selected.prepare_selected_plan, model; kwargs...)
end
Base.@nospecializeinfer @noinline function _snapshot(simulation)
    @nospecialize simulation
    return Base.invokelatest(CR.portable_downstream_snapshot, simulation)
end
Base.@nospecializeinfer @noinline function _report(simulation)
    @nospecialize simulation
    return Base.invokelatest(Selected.selected_plan_report, simulation)
end
Base.@nospecializeinfer @noinline function _step(simulation)
    @nospecialize simulation
    Base.invokelatest(PSE.step!, simulation)
    return nothing
end
Base.@nospecializeinfer @noinline function _selected_batch(simulation)
    @nospecialize simulation
    return only(batch for batch in simulation.execution_plan.batches
        if batch isa Selected.SelectedTightBatch)
end

"""Two original PB roots, real child calls and no full-protocol frame construction."""
function selected_pb_checks(; nobjects=2, steps=2, output_modes=(:none, :all),
    storage_modes=(false, true), bounded_modes=(false,), reuse=false)
    reports = Any[]
    @testset "Direct selected preparation skips full frames and preserves real PB" begin
        for native in storage_modes, bounded in bounded_modes, outputs in output_modes
            reference = PSE.run!(Native.pb_native_fixture(; native=false, nobjects, steps).model;
                steps=0, outputs)
            fixture = Native.pb_native_fixture(; native, nobjects, steps)
            candidate = _prepare(fixture.model; bounded, reuse, steps=0, outputs,
                state_strategy=native ? :native : :references, count_calls=true)
            prepared = _report(candidate)
            @test prepared.selected_batches_prepared == 1
            @test prepared.selected_rows_prepared == nobjects
            @test prepared.shared_frames_materialized == 0
            @test prepared.constructed_rich_targets == 0
            canonical = PSE.model_status(fixture.model, 1)
            escaped = PSE.refvalue(canonical, :Ra_SW_f)
            for step in 1:steps
                _step(reference); _step(candidate)
                @test isequal(_snapshot(candidate), _snapshot(reference))
                if step < steps
                    escaped[] += oftype(escaped[], 1)
                    PSE.model_status(reference.model, 1).Ra_SW_f += 1
                end
            end
            report = _report(candidate)
            @test report.executed_numerical_roots == nobjects * steps
            @test report.executed_numerical_calls > 0
            @test report.typed_model_lookups > 0
            @test report.batch_executions == steps
            @test report.fallback_batch_executions == 0
            @test report.shared_frames_materialized == 0
            @test report.constructed_rich_targets == 0
            @test PSE.model_status(fixture.model, 1) === canonical
            @test PSE.refvalue(canonical, :Ra_SW_f) === escaped
            push!(reports, (; native, bounded, outputs, report))
        end
    end
    return (; passed=true, reports)
end

PSE.@process "selected_plan_root" verbose=false
PSE.@process "selected_plan_middle" verbose=false
PSE.@process "selected_plan_worker" verbose=false
PSE.@process "selected_plan_public" verbose=false
struct SelectedRoot <: AbstractSelected_Plan_RootModel
    catch_child::Bool
end
struct SelectedMiddle <: AbstractSelected_Plan_MiddleModel end
struct SelectedWorker <: AbstractSelected_Plan_WorkerModel
    throw_first::Bool
end
struct PublicRoot <: AbstractSelected_Plan_PublicModel end
PSE.inputs_(::SelectedRoot) = (;)
PSE.inputs_(::SelectedMiddle) = (;)
PSE.inputs_(::SelectedWorker) = (fail=PSE.Default(false),)
PSE.inputs_(::PublicRoot) = (;)
PSE.outputs_(::SelectedRoot) = (root_visits=0, caught=false)
PSE.outputs_(::SelectedMiddle) = (middle_visits=0,)
PSE.outputs_(::SelectedWorker) = (worker_visits=0, value=0.0f0)
PSE.outputs_(::PublicRoot) = (root_visits=0, observed=0.0f0)

function PSE.run!(model::SelectedRoot, status, environment, constants, context)
    try
        PSE.run_call!(context, :middle; sampled_environment=environment, publish=false)
    catch error
        model.catch_child && error isa ErrorException && error.msg == "selected controlled failure" || rethrow()
        status.caught = true
        PSE.run_call!(context, :middle; sampled_environment=environment, publish=false)
    end
    status.root_visits += 1
    return nothing
end
function PSE.run!(::SelectedMiddle, status, environment, constants, context)
    status.middle_visits += 1
    PSE.run_call!(context, :worker; sampled_environment=environment, publish=false)
    return nothing
end
function PSE.run!(model::SelectedWorker, status, environment, constants, context)
    status.worker_visits += 1
    status.fail && throw(ArgumentError("selected unhandled failure"))
    model.throw_first && status.worker_visits == 1 && error("selected controlled failure")
    status.value += 0.5f0
    return nothing
end
function PSE.run!(::PublicRoot, status, environment, constants, context)
    context isa PSE.RunContext || error("Public-context model received a private context")
    targets = PSE.run_call!(context, :worker; sampled_environment=environment, publish=true)
    isempty(constants.capture) && push!(constants.capture, targets)
    status.observed = only(targets).status.value
    status.root_visits += 1
    return nothing
end
for T in (SelectedRoot, SelectedMiddle, SelectedWorker)
    @eval Native.native_call_effects(::Type{$T}) = :fixed_native_calls
    @eval Native.direct_status_compatible(::Type{$T}) = true
    @eval Shared.shared_context_effects(::Type{$T}) = :synchronous_borrowed_context
    @eval Tight.tight_call_effects(::Type{$T}) = Tight._TIGHT_CAPABILITY
end

function _fixture(native; nobjects=2, throw_first=false, catch_child=true)
    return PSE.CompositeModel((PSE.Object(id; kind=:selected_unit, status=(
        root_visits=0, caught=false, middle_visits=0, worker_visits=0,
        value=0.0f0, fail=false)) for id in 1:nobjects)...;
        applications=(
            PSE.ModelSpec(SelectedRoot(catch_child); name=:root,
                on=PSE.Many(kind=:selected_unit), every=Hour(1), calls=(
                    middle=PSE.One(within=PSE.Self(), application=:middle),)),
            PSE.ModelSpec(SelectedMiddle(); name=:middle,
                on=PSE.Many(kind=:selected_unit), every=Hour(1), calls=(
                    worker=PSE.One(within=PSE.Self(), application=:worker),)),
            PSE.ModelSpec(SelectedWorker(throw_first); name=:worker,
                on=PSE.Many(kind=:selected_unit), every=Hour(1))),
        environment=(duration=Hour(1),),
        status_storage=native ? PSE.NativeColumnStorage() : nothing)
end

function selected_exception_checks()
    reports = Any[]
    @testset "Direct selected real child frames preserve catch and retry" begin
        for native in (false, true), throw_first in (false, true)
            reference = PSE.run!(_fixture(false; throw_first); steps=0, outputs=:all)
            candidate = _prepare(_fixture(native; throw_first); steps=0, outputs=:all,
                state_strategy=native ? :native : :references, count_calls=true)
            for _ in 1:2
                _step(reference); _step(candidate)
                @test isequal(_snapshot(candidate), _snapshot(reference))
            end
            report = _report(candidate)
            @test report.executed_numerical_roots == 4
            @test report.executed_numerical_calls == (throw_first ? 12 : 8)
            @test report.shared_frames_materialized == 0
            @test report.constructed_rich_targets == 0
            push!(reports, (; native, throw_first, report))
        end
    end
    return (; passed=true, reports)
end

function _ordinary_root(simulation, id)
    return only(target for batch in simulation.execution_plan.batches
        for target in batch.targets if batch.application.id === :root && target.object_id == PSE.ObjectId(id))
end

function selected_retirement_checks()
    reports = Any[]
    @testset "Selected lazy fallback preserves retained targets through growth" begin
        for native in (false, true), consume_refresh in (false, true)
            reference = PSE.run!(_fixture(false); steps=0, outputs=:all)
            fixture = _fixture(native)
            candidate = _prepare(fixture; steps=0, outputs=:all,
                state_strategy=native ? :native : :references, count_calls=true)
            canonical = PSE.model_status(candidate.model, 1)
            escaped = PSE.refvalue(canonical, :value)
            _step(reference); _step(candidate)
            @test isequal(_snapshot(candidate), _snapshot(reference))
            batch = _selected_batch(candidate)
            @test _report(candidate).shared_frames_materialized == 0
            @test length(batch.targets) == 2
            @test _report(candidate).shared_frames_materialized == 0
            left_owner = _ordinary_root(reference, 1)
            right_owner = first(batch.targets)
            @test right_owner.context.time == left_owner.context.time == 1.0
            @test right_owner.status === canonical
            @test !batch.factory.active
            left = PSE.call_targets(left_owner.context, :middle)
            right = PSE.call_targets(right_owner.context, :middle)
            @test right isa PSE.CallTargets
            @test only(right).time == only(left).time == 1.0
            @test PSE.refvalue(only(right).status, :value) === escaped
            @test _report(candidate).fallback_programs_materialized == 1
            _step(reference); _step(candidate)
            @test isequal(_snapshot(candidate), _snapshot(reference))
            for simulation in (reference, candidate)
                PSE.register_object!(simulation.model, PSE.Object(:spectator; status=(sentinel=1.0f0,)))
                if consume_refresh
                    PSE.refresh_bindings!(simulation.model)
                    PSE.refresh_environment_bindings!(simulation.model)
                end
            end
            _step(reference); _step(candidate)
            @test isequal(_snapshot(candidate), _snapshot(reference))
            @test right.time == left.time
            @test only(right).time == only(left).time
            PSE.run_call!(only(left); sampled_environment=(duration=Hour(1),), publish=true)
            PSE.run_call!(only(right); sampled_environment=(duration=Hour(1),), publish=true)
            @test isequal(_snapshot(candidate), _snapshot(reference))
            @test PSE.model_status(candidate.model, 1) === canonical
            @test PSE.refvalue(canonical, :value) === escaped
            @test _report(candidate).fallback_programs_materialized == 1
            @test _report(candidate).live_selected_batches == 0
            push!(reports, (; native, consume_refresh, report=_report(candidate)))
        end
    end
    return (; passed=true, reports)
end

function selected_partial_exception_checks()
    reports = Any[]
    @testset "Selected unhandled failure lazily preserves unentered row epochs" begin
        for native in (false, true)
            reference = PSE.run!(_fixture(false; nobjects=3); steps=0, outputs=:all)
            candidate = _prepare(_fixture(native; nobjects=3); steps=0, outputs=:all,
                state_strategy=native ? :native : :references, count_calls=true)
            _step(reference); _step(candidate)
            PSE.model_status(reference.model, 2).fail = true
            PSE.model_status(candidate.model, 2).fail = true
            left_error = try _step(reference); nothing catch error; error end
            right_error = try _step(candidate); nothing catch error; error end
            @test left_error isa ArgumentError
            @test typeof(right_error) === typeof(left_error)
            @test sprint(showerror, right_error) == sprint(showerror, left_error)
            @test PSE.current_step(candidate) == PSE.current_step(reference) == 1
            @test isequal(_snapshot(candidate), _snapshot(reference))
            @test _report(candidate).shared_frames_materialized == 0
            batch = _selected_batch(candidate)
            owners = collect(batch.targets)
            @test [owner.context.time for owner in owners] == [2.0, 2.0, 1.0]
            @test !batch.factory.active
            for owner in owners
                control = _ordinary_root(reference, owner.object_id)
                @test owner.context.time == control.context.time
                @test !owner.call_context_cache.in_use
                expected = PSE.call_targets(control.context, :middle)
                actual = PSE.call_targets(owner.context, :middle)
                @test actual.time == expected.time == owner.context.time
                @test only(actual).time == only(expected).time
                @test !only(actual).context_cache.in_use
            end
            @test _report(candidate).executed_numerical_roots == 5
            @test _report(candidate).executed_numerical_calls == 10
            @test _report(candidate).fallback_programs_materialized == 1
            push!(reports, (; native, report=_report(candidate)))
        end
    end
    return (; passed=true, reports)
end

function _public_fixture(native)
    return PSE.CompositeModel(PSE.Object(1; status=(root_visits=0, observed=0.0f0,
        worker_visits=0, value=0.0f0, fail=false)); applications=(
            PSE.ModelSpec(PublicRoot(); name=:root, on=PSE.One(id=1), every=Hour(1), calls=(
                worker=PSE.One(within=PSE.Self(), application=:worker),)),
            PSE.ModelSpec(SelectedWorker(false); name=:worker, on=PSE.One(id=1), every=Hour(1))),
        environment=(duration=Hour(1),),
        status_storage=native ? PSE.NativeColumnStorage() : nothing)
end
function selected_public_fallback_checks()
    reports = Any[]
    @testset "Public-context and publishing models remain fully ordinary" begin
        for native in (false, true)
            left, right = (capture=Any[],), (capture=Any[],)
            reference = PSE.run!(_public_fixture(false); steps=0, outputs=:all, constants=left)
            candidate = _prepare(_public_fixture(native); steps=0, outputs=:all,
                state_strategy=native ? :native : :references, constants=right, count_calls=true)
            @test _report(candidate).selected_batches_prepared == 0
            @test _report(candidate).ordinary_targets_prepared > 0
            for _ in 1:3
                _step(reference); _step(candidate)
                @test isequal(_snapshot(candidate), _snapshot(reference))
            end
            @test only(right.capture) isa PSE.CallTargets
            @test only(right.capture).time == only(left.capture).time
            @test only(only(right.capture)).time == only(only(left.capture)).time
            @test _report(candidate).shared_frames_materialized == 0
            @test _report(candidate).executed_numerical_roots == 0
            push!(reports, (; native, report=_report(candidate)))
        end
    end
    return (; passed=true, reports)
end

"""Adversarial cold view proof: later rejection credits no discarded frames."""
function selected_mixed_union_rejection_check()
    simulation = PSE.run!(_fixture(false); steps=0, outputs=:none)
    compiled = simulation.compiled
    key = (:worker, PSE.ObjectId(2))
    previous = compiled.status_views_by_target[key]
    # This intentionally inconsistent, never-executed logical view has a
    # different numerical schema and no exact canonical identity. Row one's
    # cohort passes the union proof; the later cohort must reject the entire
    # application before any selected private frame is constructed.
    changed = PSE.Status(merge(PSE._status_vars(previous.status), (value=Ref(0.0),)))
    compiled.status_views_by_target[key] = PSE.CompiledModelStatusView(changed,
        previous.canonical_status, previous.temporal_inputs, previous.private_outputs,
        previous.bound_inputs)
    record = Selected.SelectedRecord(nothing, :same_object_union)
    chosen = Base.invokelatest(Selected._lower_selected, compiled,
        simulation.environment_bindings, compiled.applications_by_id[:root],
        simulation.temporal_streams, simulation.output_retention, simulation.constants,
        :references, :refs, :same_object_union, record)
    @testset "A late union-cohort rejection credits no selected frames" begin
        @test chosen.reason === :union_header_requires_identical_canonical_status
        @test chosen.batches === nothing
        @test record.shared.program_nodes == 6
        @test record.selected_batches == 0
        @test record.selected_rows == 0
        @test record.tight_frames == 0
        @test record.shared.shared_contexts == 0
    end
    return (; passed=true, reason=chosen.reason, program_nodes=record.shared.program_nodes,
        selected_batches=record.selected_batches, tight_frames=record.tight_frames)
end

function selected_plan_checks(; include_combined=false)
    return (; pb=selected_pb_checks(; bounded_modes=include_combined ? (false, true) : (false,)),
        exceptions=selected_exception_checks(), public=selected_public_fallback_checks(),
        retirement=selected_retirement_checks(), partial=selected_partial_exception_checks(),
        union_rejection=selected_mixed_union_rejection_check())
end

end # module
