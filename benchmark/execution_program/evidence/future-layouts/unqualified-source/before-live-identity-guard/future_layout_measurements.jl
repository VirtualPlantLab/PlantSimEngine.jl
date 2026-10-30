module FutureLayoutMeasurements

using Dates, SHA, PlantSimEngine
const PSE=PlantSimEngine
const Fixtures=Main.FutureLayoutFixtures
const ARMS=(:reference_executor,:future_precompile,:bounded_preparation,:combined)
const MEASUREMENT_COUNT=Ref(0)

export ARMS, run_future_layout_case, future_layout_case_state, prepare_future_arm

_uses_future(arm)=arm in (:future_precompile,:combined)
_uses_bounded(arm)=arm in (:bounded_preparation,:combined)
_future()=getfield(Main,:FutureLayouts)
_bounded()=getfield(Main,:BoundedPreparation)

function _stage(path,kind,arm,label)
    path===nothing && return nothing
    mkpath(dirname(abspath(path)))
    open(path,"a") do io
        write(io,string(Dates.now(Dates.UTC)),'\t',string(kind),'\t',string(arm),'\t',label,'\n')
        flush(io)
    end
    return nothing
end

Base.@nospecializeinfer @noinline function _timed_call(f,args...;kwargs...)
    @nospecialize f args
    return @timed Base.invokelatest(f,args...;kwargs...)
end
Base.@nospecializeinfer @noinline function _phase_record(measurement)
    @nospecialize measurement
    return (seconds=measurement.time,allocated_bytes=measurement.bytes,
        gc_seconds=measurement.gctime,
        compilation_seconds=hasproperty(measurement,:compile_time) ? measurement.compile_time : nothing,
        recompilation_seconds=hasproperty(measurement,:recompile_time) ? measurement.recompile_time : nothing)
end

Base.@nospecializeinfer @noinline function prepare_future_arm(fixture,arm;outputs=:all)
    @nospecialize fixture
    _uses_bounded(arm) && Base.invokelatest(_bounded().enable_bounded_preparation!,fixture.model)
    return Base.invokelatest(PSE.run!,fixture.model;steps=0,outputs)
end

Base.@nospecializeinfer @noinline function _blueprint_stage(simulation,fixture,arm;
    outputs=:all,max_requests=12,status_max_requests=2)
    @nospecialize simulation fixture
    # These same cheap guards are INSIDE this timed phase for every arm. Full
    # state snapshots/type matching are deferred until after timed execution.
    before=Base.invokelatest(Fixtures.fixture_guard,fixture)
    task_before=Base.invokelatest(Fixtures.task_rng_state)
    catalogue=nothing
    if _uses_future(arm)
        Future=_future()
        archetype=Base.invokelatest(Future.FutureArchetype,:declared_future,
            fixture.future_builder;environment_types=fixture.environment_types)
        catalogue=Base.invokelatest(Future.precompile_future_layouts!,simulation,
            Any[archetype];bounded=_uses_bounded(arm),outputs,
            constants=simulation.constants,max_requests,status_max_requests,
            application_filter=fixture.expected_targetless)
    end
    after=Base.invokelatest(Fixtures.fixture_guard,fixture)
    task_after=Base.invokelatest(Fixtures.task_rng_state)
    before==after || error("Future preparation changed live kernel/RNG/sample state")
    task_before==task_after || error("Future preparation changed the caller TaskLocalRNG")
    PSE.current_step(simulation)==0 || error("Future discovery advanced the live simulation")
    return (;catalogue,guard=(before,after,unchanged=true,task_rng_unchanged=true))
end

Base.@nospecializeinfer @noinline function _construct(kind;steps,seed,record_types)
    if kind===:generic
        return Base.invokelatest(Fixtures.generic_future_fixture;steps,seed,record_types)
    end
    return Base.invokelatest(getfield(Fixtures,:downstream_future_fixture),kind;
        steps,seed,record_types)
end

"""
Run exactly one arm with explicit cold boundaries and persistent stage markers.
Any/dynamic orchestration prevents inference across several huge Simulation
families. No full snapshots, signature matching or IR inspection occur before
timed execution. Blueprint construction/zero-step preparation/precompile and its
guards are charged to future_blueprint_precompile, including in complete cost.
Caller owns fresh-process first-use attestations; disk caches remain available.
"""
Base.@nospecializeinfer @noinline function future_layout_case_state(kind::Symbol=:generic,
    arm::Symbol=:reference_executor;steps=2,seed=1,outputs=:all,record_types=false,
    max_requests=12,status_max_requests=2,progress_path=nothing,freshness=nothing)
    arm in ARMS || throw(ArgumentError("Unknown future-layout arm: $arm"))
    steps>0 || throw(ArgumentError("Positive steps required"))
    freshness===nothing || all(name->hasproperty(freshness,name) &&
        getproperty(freshness,name)===true,
        (:new_process,:no_prior_case_execution,:no_prior_ir_probe)) ||
        throw(ArgumentError("Invalid first-use freshness attestation"))
    if freshness!==nothing
        iszero(MEASUREMENT_COUNT[]) || error("Use a fresh Kaimon worker for each cold arm")
        hasproperty(freshness,:pid) && freshness.pid!=getpid() &&
            error("Freshness attestation identifies another worker")
        hasproperty(freshness,:previous_pid) && freshness.previous_pid==getpid() &&
            error("Cold worker PID must differ from the previous worker")
    end
    MEASUREMENT_COUNT[]+=1
    state=Dict{Symbol,Any}()
    phases=Dict{Symbol,Any}()
    _stage(progress_path,kind,arm,"before_construction")
    measured=_timed_call(_construct,kind;steps,seed,record_types)
    state[:fixture]=measured.value
    phases[:construction]=_phase_record(measured)
    _stage(progress_path,kind,arm,"after_construction")
    _stage(progress_path,kind,arm,"before_normal_preparation")
    measured=_timed_call(prepare_future_arm,state[:fixture],arm;outputs)
    state[:simulation]=measured.value
    phases[:normal_preparation]=_phase_record(measured)
    _stage(progress_path,kind,arm,"after_normal_preparation")
    _stage(progress_path,kind,arm,"before_future_blueprint_precompile")
    measured=_timed_call(_blueprint_stage,state[:simulation],state[:fixture],arm;
        outputs,max_requests,status_max_requests)
    state[:catalogue]=measured.value.catalogue
    state[:guard]=measured.value.guard
    phases[:future_blueprint_precompile]=_phase_record(measured)
    _stage(progress_path,kind,arm,"after_future_blueprint_precompile")
    _stage(progress_path,kind,arm,"before_first_growth_execution")
    measured=_timed_call(PSE.step!,state[:simulation])
    phases[:first_growth_execution]=_phase_record(measured)
    _stage(progress_path,kind,arm,"after_first_growth_execution")
    if steps>1
        _stage(progress_path,kind,arm,"before_remaining_execution")
        measured=_timed_call(PSE.continue!,state[:simulation];steps=steps-1)
        phases[:remaining_execution]=_phase_record(measured)
        _stage(progress_path,kind,arm,"after_remaining_execution")
    end
    state[:phases]=phases
    state[:config]=(;kind,arm,steps,seed,outputs,record_types,max_requests,status_max_requests,
        freshness,process_id=getpid(),julia=string(VERSION),source=Base.pathof(PSE))
    return state
end

"""Portable result only; live simulation/catalogue objects never enter JSON."""
Base.@nospecializeinfer @noinline function run_future_layout_case(kind::Symbol=:generic,
    arm::Symbol=:reference_executor;expected_digest=nothing,kwargs...)
    state=Base.invokelatest(future_layout_case_state,kind,arm;kwargs...)
    simulation,fixture=state[:simulation],state[:fixture]
    _stage(get(kwargs,:progress_path,nothing),kind,arm,"before_postexecution_diagnostics")
    snapshot=(scientific=Base.invokelatest(Fixtures.portable_snapshot,simulation;kind),
        model_rngs=Base.invokelatest(Fixtures.model_rng_fingerprint,simulation.model))
    digest=bytes2hex(sha256(repr(snapshot)))
    expected_digest===nothing || expected_digest==digest || error("Future-layout state/history mismatch")
    catalogue=state[:catalogue]
    future_report=catalogue===nothing ? nothing :
        Base.invokelatest(_future().future_layout_report,catalogue)
    status_matches=catalogue===nothing ? nothing :
        Base.invokelatest(_future().match_future_status_layouts,catalogue,simulation)
    observations=Base.invokelatest(Fixtures.generic_observations,fixture)
    kernel_matches=catalogue===nothing || isempty(observations) ? nothing :
        Base.invokelatest(_future().match_observed_kernel_layouts,catalogue,observations)
    bounded_report=isdefined(Main,:BoundedPreparation) ?
        Base.invokelatest(_bounded().bounded_preparation_report,simulation) : nothing
    phases=state[:phases]
    complete=sum(value.seconds for value in values(phases))
    all_preparation=phases[:normal_preparation].seconds+
        phases[:future_blueprint_precompile].seconds
    _stage(get(kwargs,:progress_path,nothing),kind,arm,"after_postexecution_diagnostics")
    return (config=state[:config],phases,complete_seconds=complete,
        all_preparation_seconds=all_preparation,
        complete_allocated_bytes=sum(value.allocated_bytes for value in values(phases)),
        guard=state[:guard],snapshot,digest,future_report,status_matches,kernel_matches,
        bounded_report,final_probe=Base.invokelatest(Fixtures.fixture_guard,fixture),
        interpretation=:precompile_can_shift_JIT_cost_not_necessarily_reduce_total,
        diagnostics_scope=:full_snapshots_and_type_matching_after_timed_execution)
end

end
