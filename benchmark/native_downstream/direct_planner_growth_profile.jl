module DirectPlannerGrowthProfile

using Profile, SHA, PlantSimEngine
const PSE=PlantSimEngine
const F=Main.DirectPlannerFixtures
const H=Main.DirectPlannerMeasurements
const CR=Main.CompiledRegionsExperiment
export profile_growth_case, framework_growth_companion, compact_growth_samples,
    generic_growth_differential

const PHASE_FUNCTIONS=(
    targeted_newborn=("_targeted_new_object_call_targets",),
    logical_extension=("_extend_compiled_scene",),
    input_preparation=("_compile_added_consumer_bindings!","_prepare_model_input_statuses_batched!"),
    status_views=("_prepare_compiled_model_status_view","_extend_model_status_views"),
    environments=("_targeted_call_environment_bindings","_refresh_environment_bindings_for_objects",
        "refresh_environment_bindings!"),
    writer_destinations=("_refresh_model_distributed_outputs","_incremental_distributed_output_addition!"),
    execution_group_refresh=("_refresh_model_execution_plan","_refresh_model_execution_group_delta!",
        "_try_refresh_model_execution_plan_for_pure_addition!"),
    runtime_refresh=("_refresh_simulation_runtime!",),
)

"""Bounded Julia1.13 CPU sampling report; never pretty-print method instances.

Counts are inclusive/overlapping samples, not disjoint elapsed phase timings.
Only active stacks containing source frames from this PSE checkout are selected.
The phase table supplements existing runtime counters; it does not invent
targeted-preparation counters, exact allocation attribution or JIT causality.
"""
Base.@nospecializeinfer @noinline function compact_growth_samples(;data=Profile.fetch(),limit=32)
    isempty(data) || Profile.has_meta(data) || error("Profile metadata required")
    lookup=Profile.getdict(data)
    phases=Dict(name=>0 for name in keys(PHASE_FUNCTIONS))
    functions=Dict{Tuple{String,String},Int}()
    selected=total=active=unresolved=0
    last_end=0
    for finish in eachindex(data)
        finish>=6 || continue
        data[finish]==0 && data[finish-1]==0 || continue
        data[finish-2] in (UInt(1),UInt(2),UInt(3)) || continue
        data[finish-3]!=0 && data[finish-4]!=0 && data[finish-5]!=0 || continue
        total+=1
        first_ip,final_ip=last_end+1,finish-6
        last_end=finish
        data[finish-2]==UInt(2) && continue
        active+=1
        frames_in_sample=Set{Tuple{String,String}}()
        matches=false
        for index in first_ip:final_ip
            ip=data[index]
            iszero(ip) && continue
            resolved=get(lookup,ip,nothing)
            if resolved===nothing
                unresolved+=1
                continue
            end
            for frame in resolved
                frame.from_c && continue
                file=String(frame.file)
                func=String(frame.func)
                push!(frames_in_sample,(func,file))
                matches|=occursin("PlantSimEngine",file)
            end
        end
        matches || continue
        selected+=1
        for key in frames_in_sample
            functions[key]=get(functions,key,0)+1
        end
        for (phase,names) in pairs(PHASE_FUNCTIONS)
            any(key->any(name->occursin(name,key[1]),names),frames_in_sample) && (phases[phase]+=1)
        end
    end
    ordered=sort!(collect(keys(functions));by=key->(-functions[key],key[2],key[1]))
    rows=[(function_name=key[1],file=key[2],inclusive=functions[key])
        for key in Iterators.take(ordered,limit)]
    return (samples_total=total,samples_active=active,samples_selected=selected,
        unresolved_ips=unresolved,trailing_raw_ips=length(data)-last_end,
        inclusive_phase_samples=phases,
        inclusive_phase_shares=Dict(name=>(selected==0 ? nothing : count/selected)
            for (name,count) in phases),functions=rows,
        interpretation=:overlapping_CPU_samples_not_precise_or_additive_phase_times,
        sample_qualification=selected>=100 ? :coarse_sampling : :too_few_samples_for_stable_shares)
end

Base.@nospecializeinfer @noinline function _state(kind,arm,config;performance=false)
    @nospecialize config
    fixture=Base.invokelatest(F.construct_fixture,kind,config)
    simulation=Base.invokelatest(H.prepare_arm,fixture.model,arm;
        outputs=config.outputs,performance,count_calls=false)
    return Dict{Symbol,Any}(:fixture=>fixture,:simulation=>simulation)
end
Base.@nospecializeinfer @noinline function _execute_states!(states,steps)
    @nospecialize states
    for state in states
        Base.invokelatest(PSE.continue!,state[:simulation];steps)
    end
    return nothing
end
Base.@nospecializeinfer @noinline function _profile_states!(states,steps)
    @nospecialize states
    Profile.@profile Base.invokelatest(_execute_states!,states,steps)
    return nothing
end
Base.@nospecializeinfer @noinline function _observation(state,kind,arm;instrumented=false)
    @nospecialize state
    simulation,fixture=state[:simulation],state[:fixture]
    snapshot=(state=Base.invokelatest(F.snapshot,simulation,kind),
        scientific_rngs=Base.invokelatest(F.scientific_rngs,simulation.model))
    return (digest=bytes2hex(sha256(repr(snapshot))),snapshot,
        work=Base.invokelatest(CR.downstream_work_report,simulation,fixture.initial_ids),
        coverage=Base.invokelatest(H.coverage,simulation,arm,kind;instrumented))
end
function _counter_delta(before,after)
    return (counts=Dict(name=>get(after.counts,name,0)-get(before.counts,name,0)
            for name in union(keys(before.counts),keys(after.counts))),
        elapsed_seconds=Dict(name=>get(after.elapsed_seconds,name,0.0)-get(before.elapsed_seconds,name,0.0)
            for name in union(keys(before.elapsed_seconds),keys(after.elapsed_seconds))))
end

"""Separate opt-in framework timing/count companion, not a normal benchmark.

Record counter deltas after zero-step preparation, including per-step affected
bindings/views/targets, existing logical-extension subphases and environment /
execution-plan refresh. Instrumentation may force the selected driver onto its
ordinary path; coverage records that fact and never credits it as optimized.
Existing phase times nest and overlap. Per-phase allocations are not measured.
"""
Base.@nospecializeinfer @noinline function framework_growth_companion(kind::Symbol=:xp,
    arm::Symbol=:reference_executor;steps=2,nobjects=128,additions=3,outputs=:none,
    seed=1,emission_speed=0.2,expected_digest=nothing)
    config=H.construct_config(kind;steps,nobjects,additions,outputs,seed,emission_speed)
    state=Base.invokelatest(_state,kind,arm,config;performance=true)
    simulation=state[:simulation]
    before=Base.invokelatest(PSE.runtime_performance,simulation)
    steps_report=Any[]
    for step in 1:steps
        Base.invokelatest(PSE.step!,simulation)
        after=Base.invokelatest(PSE.runtime_performance,simulation)
        push!(steps_report,(;step,performance=_counter_delta(before,after)))
        before=after
    end
    observed=Base.invokelatest(_observation,state,kind,arm;instrumented=true)
    expected_digest===nothing || observed.digest==expected_digest || error("Instrumented companion differs")
    return (;kind,arm,config,policies=H.policies(arm),steps_report,
        final_framework_performance=Base.invokelatest(PSE.runtime_performance,simulation),
        observed,interpretation=:instrumented_framework_counts_and_nested_times_not_candidate_benchmark,
        per_phase_allocations=:not_measured,
        targeted_preparation=:CPU_sampling_only_no_invented_exact_timer)
end

"""Profile actual uninstrumented candidate execution on independent scenarios.

One independent same-arm run warms only this diagnostic companion. Fresh scenes
are then prepared before CPU sampling. Timed product comparisons must use H's
uninstrumented benchmark instead. No Profile.print, IR inspection, scientific
RNG probing, snapshots or report formatting occurs within the sampled region.
First call with one/two XP days; expand repetitions only if samples are sparse.
"""
Base.@nospecializeinfer @noinline function profile_growth_case(kind::Symbol=:xp,
    arm::Symbol=:reference_executor;steps=2,nobjects=128,additions=3,outputs=:none,
    seed=1,emission_speed=0.2,repetitions::Int=5,delay=0.0005,
    include_framework=true,expected_digest=nothing,progress_path=nothing)
    repetitions>0 || error("Positive repetitions required")
    config=H.construct_config(kind;steps,nobjects,additions,outputs,seed,emission_speed)
    H._stage(progress_path,kind,arm,"before_profile_warmup")
    warm=Base.invokelatest(_state,kind,arm,config)
    Base.invokelatest(_execute_states!,Any[warm],steps)
    oracle=Base.invokelatest(_observation,warm,kind,arm)
    expected_digest===nothing || oracle.digest==expected_digest || error("Warm diagnostic differs")
    states=Any[Base.invokelatest(_state,kind,arm,config) for _ in 1:repetitions]
    H._stage(progress_path,kind,arm,"before_CPU_profile")
    Profile.init(n=2^20,delay=delay)
    Profile.clear()
    measured=H._timed(_profile_states!,states,steps)
    H._stage(progress_path,kind,arm,"after_CPU_profile")
    samples=Base.invokelatest(compact_growth_samples)
    observations=Any[]
    for state in states
        observed=Base.invokelatest(_observation,state,kind,arm)
        observed.digest==oracle.digest || error("Sampled scientific state/history/RNG differs")
        observed.work==oracle.work || error("Sampled work differs")
        push!(observations,observed)
    end
    framework=include_framework ? Base.invokelatest(framework_growth_companion,kind,arm;
        steps,nobjects,additions,outputs,seed,emission_speed,expected_digest=oracle.digest) : nothing
    H._stage(progress_path,kind,arm,"after_profile_diagnostics")
    return (;kind,arm,config,policies=H.policies(arm),repetitions,pid=getpid(),
        samples,
        inclusive_phase_samples_per_simulation=Dict(name=>count/repetitions
            for (name,count) in samples.inclusive_phase_samples),
        diagnostic_measurement=H._phase(measured),digest=oracle.digest,
        observations,framework,
        qualification=:normal_execution_sampled_separately_from_instrumented_framework_counters,
        benchmark_claim=false)
end

"""Optional fixed-Delta compiler scaling diagnostic, not a science speed ratio.

Compare no addition against +3 (or another explicit small delta) at a fixed
existing population. Counter subphases isolate refresh from the necessarily
larger scientific loop and Many reduction. Call separately at128/1024; this
function starts no large matrix or CPU sampler.
"""
Base.@nospecializeinfer @noinline function generic_growth_differential(;
    arm::Symbol=:reference_executor,nobjects=128,additions=3,steps=1,outputs=:none)
    no_growth=Base.invokelatest(framework_growth_companion,:generic,arm;
        nobjects,additions=0,steps,outputs)
    growth=Base.invokelatest(framework_growth_companion,:generic,arm;
        nobjects,additions,steps,outputs)
    return (;arm,nobjects,additions,steps,no_growth,growth,
        interpretation=:separate_refresh_counters_from_scientific_population_scaling,
        total_execution_speedup_claim=false)
end

end # module
