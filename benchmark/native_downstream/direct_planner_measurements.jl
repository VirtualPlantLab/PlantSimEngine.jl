module DirectPlannerMeasurements

using Dates, SHA, Test, PlantSimEngine
const PSE=PlantSimEngine
const F=Main.DirectPlannerFixtures
const M=Main.NativeDownstreamMeasurements
const CR=Main.CompiledRegionsExperiment
const PB=Main.NativePBDriver
const XP=Main.NativeXPDriver
const ARMS=(:reference_executor,:bounded_preparation,:planner_boundaries,
    :selected_driver,:combined)
const OPTIONAL_ARMS=(:bounded_selected,:bounded_combined,:prior_typed)
const COLD_COUNT=Ref(0)
export ARMS, policies, prepare_arm, coverage, direct_planner_checks,
    register_direct_planner_pb_case!, register_direct_planner_xp_case!,
    register_direct_planner_generic_case!, run_direct_planner_case, construct_config

function policies(arm)
    arm in (ARMS...,OPTIONAL_ARMS...) || throw(ArgumentError("Unknown arm: $arm"))
    return (bounded=arm in (:bounded_preparation,:bounded_selected,:bounded_combined),
        planner=arm in (:planner_boundaries,:combined,:bounded_combined),
        driver=arm in (:selected_driver,:combined,:bounded_selected,:bounded_combined) ?
            :selected : arm===:prior_typed ? :prior_typed : :ordinary)
end
construct_config(kind;steps=kind===:xp ? 2 : 2,nobjects=2,additions=3,seed=1,
    emission_speed=0.2,outputs=:none)=(;kind,steps,nobjects,additions,seed,
        emission_speed=Float64(emission_speed),outputs)

Base.@nospecializeinfer @noinline function prepare_arm(model,arm;
    outputs=:none,performance=false,count_calls=false,constants=PSE.PlantMeteo.Constants())
    @nospecialize model outputs constants
    model.status_storage===nothing || error("Factorial retains ordinary canonical references")
    policy=policies(arm)
    policy.bounded && Base.invokelatest(getfield(Main,:BoundedPreparation).enable_bounded_preparation!,model)
    policy.planner && Base.invokelatest(getfield(Main,:PlannerBoundaries).enable_planner_boundaries!,model)
    if policy.driver===:selected
        return Base.invokelatest(getfield(Main,:DirectPlanConstruction).prepare_selected_plan,
            model;steps=0,outputs,performance,count_calls,constants,
            state_strategy=:references,status_strategy=:refs,header_strategy=:projected)
    elseif policy.driver===:prior_typed
        return Base.invokelatest(getfield(Main,:TightCallProgram).prepare_tight_calls,
            model;steps=0,outputs,performance,count_calls,constants,
            state_strategy=:references,status_strategy=:refs,header_strategy=:projected)
    end
    return Base.invokelatest(PSE.run!,model;steps=0,outputs,performance,constants)
end

Base.@nospecializeinfer @noinline function coverage(simulation,arm,kind;instrumented=false)
    @nospecialize simulation
    policy=policies(arm)
    bounded=Base.invokelatest(getfield(Main,:BoundedPreparation).bounded_preparation_report,simulation)
    planner=Base.invokelatest(getfield(Main,:PlannerBoundaries).planner_boundary_report,simulation)
    policy.bounded ? bounded.scene_entries>0 || error("No bounded metadata work") :
        iszero(bounded.scene_entries) || error("Bounded policy contaminated control")
    policy.planner ? planner.scene_entries>0 || error("No planner boundary work") :
        iszero(planner.scene_entries) || error("Planner policy contaminated control")
    driver=policy.driver===:selected ?
        Base.invokelatest(getfield(Main,:DirectPlanConstruction).selected_plan_report,simulation) :
        policy.driver===:prior_typed ?
        Base.invokelatest(getfield(Main,:TightCallProgram).tight_call_report,simulation) : nothing
    entries=driver===nothing ? 0 : policy.driver===:selected ?
        driver.batch_executions : driver.tight_batch_executions
    if kind===:pb && policy.driver!==:ordinary && !instrumented
        entries>0 || error("PB requested a typed driver but executed no selected batch")
    end
    return (native_fields=0,driver_units=entries,native_driver_units=0,
        driver_units_kind=:actual_entered_driver_batches_not_inferred_roots_or_children,
        policies=policy,bounded,planner,driver,instrumented,
        qualification=entries>0 ? :observed_typed_batch_execution : :ordinary_executor_or_fallback,
        canonical_storage=:ordinary_references,scientific_kernels=:original_unmodified)
end

function _stage(path,kind,arm,label)
    path===nothing && return nothing
    mkpath(dirname(abspath(path)))
    open(path,"a") do io
        write(io,string(Dates.now(Dates.UTC)),'\t',string(kind),'\t',string(arm),'\t',label,'\n')
        flush(io)
    end
    return nothing
end
Base.@nospecializeinfer @noinline function _timed(f,args...;kwargs...)
    @nospecialize f args
    return @timed Base.invokelatest(f,args...;kwargs...)
end
Base.@nospecializeinfer @noinline function _phase(value)
    @nospecialize value
    return (seconds=value.time,allocated_bytes=value.bytes,gc_seconds=value.gctime,
        compilation_seconds=hasproperty(value,:compile_time) ? value.compile_time : nothing,
        recompilation_seconds=hasproperty(value,:recompile_time) ? value.recompile_time : nothing)
end

"""One independent uninstrumented sample, with first-use phase boundaries.

No science, snapshots, RNG probing or type/report rendering occurs before the
timed execution. Freshness requires a separate Kaimon worker for every cold arm;
filesystem/package caches remain available. Future catalogues are never used.
"""
Base.@nospecializeinfer @noinline function run_direct_planner_case(kind::Symbol=:pb,
    arm::Symbol=:reference_executor;steps=kind===:xp ? 2 : 2,nobjects=2,additions=3,
    seed=1,emission_speed=0.2,outputs=:none,progress_path=nothing,freshness=nothing,
    expected_digest=nothing)
    policy=policies(arm)
    if freshness!==nothing
        all(key->hasproperty(freshness,key) && getproperty(freshness,key)===true,
            (:new_process,:no_prior_case_execution,:no_prior_ir_probe)) || error("Invalid freshness")
        iszero(COLD_COUNT[]) || error("One cold sample per fresh worker")
        hasproperty(freshness,:pid) && freshness.pid!=getpid() && error("Wrong worker PID")
        hasproperty(freshness,:previous_pid) && freshness.previous_pid==getpid() && error("Reused worker PID")
    end
    COLD_COUNT[]+=1
    config=merge(construct_config(kind;steps,nobjects,additions,seed,emission_speed,outputs),
        (policies=policy,))
    phases=Dict{Symbol,Any}()
    _stage(progress_path,kind,arm,"before_construction")
    measured=_timed(F.construct_fixture,kind,config)
    fixture=measured.value;phases[:construction]=_phase(measured)
    _stage(progress_path,kind,arm,"after_construction")
    _stage(progress_path,kind,arm,"before_preparation")
    measured=_timed(prepare_arm,fixture.model,arm;outputs)
    simulation=measured.value;phases[:preparation]=_phase(measured)
    _stage(progress_path,kind,arm,"after_preparation")
    _stage(progress_path,kind,arm,"before_first_execution")
    measured=_timed(PSE.step!,simulation)
    phases[:first_execution]=_phase(measured)
    _stage(progress_path,kind,arm,"after_first_execution")
    if steps>1
        _stage(progress_path,kind,arm,"before_remaining_execution")
        measured=_timed(PSE.continue!,simulation;steps=steps-1)
        phases[:remaining_execution]=_phase(measured)
        _stage(progress_path,kind,arm,"after_remaining_execution")
    end
    _stage(progress_path,kind,arm,"before_diagnostics")
    observed=(state=Base.invokelatest(F.snapshot,simulation,kind),
        scientific_rngs=Base.invokelatest(F.scientific_rngs,simulation.model))
    digest=bytes2hex(sha256(repr(observed)))
    expected_digest===nothing || expected_digest==digest || error("Scientific digest differs")
    report=Base.invokelatest(coverage,simulation,arm,kind)
    work=Base.invokelatest(CR.downstream_work_report,simulation,fixture.initial_ids)
    _stage(progress_path,kind,arm,"after_diagnostics")
    return (;config,arm,policies=policy,freshness,pid=getpid(),julia=string(VERSION),
        source=Base.pathof(PSE),phases,complete_seconds=sum(row.seconds for row in values(phases)),
        complete_allocated_bytes=sum(row.allocated_bytes for row in values(phases)),
        digest,snapshot=observed,coverage=report,work,
        forcing_setup=:inside_measured_construction,
        diagnostics=:after_execution_only,temperature=freshness===nothing ? :unspecified : :first_use)
end

Base.@nospecializeinfer @noinline function direct_planner_checks(kind::Symbol=:pb;
    arm::Symbol=:selected_driver,nobjects=2,steps=kind===:xp ? 2 : 2,additions=3,outputs=:all)
    reports=Dict{Symbol,Any}()
    @testset "Independent driver/planner full-state and lifecycle parity" begin
        config=construct_config(kind;steps,nobjects,additions,outputs)
        left=Base.invokelatest(F.construct_fixture,kind,config)
        right=Base.invokelatest(F.construct_fixture,kind,config)
        control=Base.invokelatest(prepare_arm,left.model,:reference_executor;outputs,count_calls=true)
        candidate=Base.invokelatest(prepare_arm,right.model,arm;outputs,count_calls=true)
        before_left=Base.invokelatest(F.identities,left.model)
        before_right=Base.invokelatest(F.identities,right.model)
        @test keys(before_left.references)==keys(before_right.references)
        @test all(key->before_left.references[key]!==before_right.references[key],keys(before_left.references))
        @test isequal(Base.invokelatest(F.snapshot,candidate,kind),Base.invokelatest(F.snapshot,control,kind))
        for _ in 1:steps
            Base.invokelatest(PSE.step!,control)
            Base.invokelatest(PSE.step!,candidate)
            @test isequal(Base.invokelatest(F.snapshot,candidate,kind),Base.invokelatest(F.snapshot,control,kind))
            @test Base.invokelatest(F.scientific_rngs,right.model)==
                Base.invokelatest(F.scientific_rngs,left.model)
            after_left=Base.invokelatest(F.identities,left.model)
            after_right=Base.invokelatest(F.identities,right.model)
            @test F.same_identity_transitions(before_left,before_right,after_left,after_right)
            before_left,before_right=after_left,after_right
        end
        @test CR.downstream_work_report(candidate,right.initial_ids)==
            CR.downstream_work_report(control,left.initial_ids)
        report=Base.invokelatest(coverage,candidate,arm,kind)
        if kind===:pb && policies(arm).driver!==:ordinary
            @test report.driver.executed_numerical_roots==nobjects*steps
            @test report.driver.executed_numerical_calls>0
        end
        reports[:coverage]=report
        reports[:work]=CR.downstream_work_report(candidate,right.initial_ids)
    end
    return (;passed=true,kind,arm,steps,reports)
end

Base.@nospecializeinfer @noinline function _register(name,kind;steps=2,nobjects=2,additions=3,
    seed=1,emission_speed=0.2,outputs=:none,arms=ARMS,replace=false)
    config=merge(construct_config(kind;steps,nobjects,additions,seed,emission_speed,outputs),
        (policies_by_arm=Dict(arm=>policies(arm) for arm in arms),))
    # Warm-suite registration may read forcing once. Every measured sample still
    # independently constructs models/RNGs/tree/state and copies its forcing.
    weather=kind===:xp ? CR._xpalm_fixture_weather(steps) : nothing
    return M.register_case!(name;config,replace,packages=(PSE,PB.PB,XP.XPalm),
        variants=Tuple(M.VariantSpec(arm) for arm in arms),
        construct=(config,variant)->Base.invokelatest(F.construct_fixture,kind,config;weather),
        prepare=(fixture,config,variant)->Base.invokelatest(prepare_arm,fixture.model,
            variant.name;outputs=config.outputs),
        lower=(simulation,fixture,config,variant)->nothing,
        execute! = (simulation,program,fixture,config,variant)->
            Base.invokelatest(PSE.continue!,simulation;steps=config.steps),
        fingerprint=(simulation,fixture,config)->(state=Base.invokelatest(F.snapshot,simulation,kind),
            scientific_rngs=Base.invokelatest(F.scientific_rngs,simulation.model)),
        coverage=(simulation,program,fixture,config,variant)->
            Base.invokelatest(coverage,simulation,variant.name,kind),
        work=(simulation,fixture,config)->CR.downstream_work_report(simulation,fixture.initial_ids))
end
register_direct_planner_pb_case!(name::Symbol=:direct_planner_pb;kwargs...)=_register(name,:pb;kwargs...)
register_direct_planner_xp_case!(name::Symbol=:direct_planner_xp;steps=4,kwargs...)=_register(name,:xp;steps,kwargs...)
register_direct_planner_generic_case!(name::Symbol=:direct_planner_generic;kwargs...)=_register(name,:generic;kwargs...)

end # module
