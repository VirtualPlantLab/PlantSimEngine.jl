module PreparationScalingColdCase

# Bootstrap-only module: loading this file imports no packages and runs no
# fixture, planner, scientific kernel, future catalogue or compiler/IR probe.
export COLD_ARMS, run_preparation_scaling_cold_case
const COLD_ARMS = (:ordinary_a, :bounded_graph, :typed_graph)
const COLD_COUNT = Ref(0)
const DRIVER_PATH = @__FILE__
const PROTOCOL = :preparation_scaling_cold_v1
const REQUIRED_IMAGE = (
    "Project.toml", "Manifest.toml", "src/PlantSimEngine.jl",
    "src/composite_model/compilation.jl", "src/composite_model/runtime_outputs.jl",
    "benchmark/native_downstream/load_experiments.jl",
    "benchmark/native_downstream/load_direct_planner_experiment.jl",
    "benchmark/native_downstream/load_newborn_binding_experiment.jl",
    "benchmark/native_downstream/direct_planner_fixtures.jl",
    "benchmark/native_downstream/direct_planner_measurements.jl",
    "benchmark/native_downstream/bounded_preparation.jl",
    "benchmark/native_downstream/graph_row_projection.jl",
    "benchmark/native_downstream/typed_output_preparation.jl",
    "benchmark/native_downstream/xp_dispatch_refresh_measurements.jl",
    "benchmark/native_downstream/pb_preparation_scaling.jl",
    "benchmark/native_downstream/xp_preparation_scaling.jl",
    "benchmark/native_downstream/preparation_scaling_cold_case.jl",
)

Base.@nospecializeinfer @noinline function _phase(value)
    @nospecialize value
    return (seconds=value.time, allocated_bytes=value.bytes, gc_seconds=value.gctime,
        compilation_seconds=hasproperty(value,:compile_time) ? value.compile_time : nothing,
        recompilation_seconds=hasproperty(value,:recompile_time) ? value.recompile_time : nothing)
end
Base.@nospecializeinfer @noinline function _timed(f,args...;kwargs...)
    @nospecialize f args
    return @timed Base.invokelatest(f,args...;kwargs...)
end
function _stage(path,kind,arm,label)
    mkpath(dirname(abspath(path)))
    open(path,"a") do io
        write(io,string(time_ns()),'\t',string(getpid()),'\t',string(kind),'\t',string(arm),'\t',label,'\n')
        flush(io)
    end
    return nothing
end
function _preimport()
    names=(:PlantSimEngine,:PlantBiophysics,:XPalm,:PlantGeom)
    in_main=NamedTuple{names}(Tuple(isdefined(Main,name) for name in names))
    loaded=Set(nameof(value) for value in values(Base.loaded_modules))
    in_loaded_modules=NamedTuple{names}(Tuple(name in loaded for name in names))
    return (;in_main,in_loaded_modules,
        scope=:facts_before_this_driver_imports_packages_not_a_claim_of_empty_disk_caches)
end
function _import_packages!(root)
    devroot=get(ENV,"PSE_DOWNSTREAM_DEV_ROOT",joinpath(homedir(),"Documents","dev"))
    for (key,fallback) in (
        ("PSE_BENCHMARK_ENV_PATH",joinpath(devroot,"PlantSimEngine","benchmark")),
        ("PSE_PLANTGEOM_PATH",joinpath(devroot,"PlantGeom")),
        ("PSE_PLANTBIOPHYSICS_PATH",joinpath(devroot,"PlantBiophysics")),
        ("PSE_XPALM_PATH",joinpath(devroot,"XPalm")),
    )
        path=get(ENV,key,fallback)
        isdir(path) && !(path in LOAD_PATH) && push!(LOAD_PATH,path)
    end
    Core.eval(Main,:(using Dates,Random,SHA,Statistics,Test))
    Core.eval(Main,:(using PlantSimEngine,PlantGeom,PlantBiophysics,XPalm))
    return nothing
end
function _check_image(root,expected)
    all(path->haskey(expected,path),REQUIRED_IMAGE) || error("Incomplete expected cold source image")
    SHA=getfield(Main,:SHA)
    actual=Dict{String,String}()
    for (key,digest) in pairs(expected)
        relative=String(key)
        isabspath(relative) && error("Source image paths must be project-relative")
        path=normpath(joinpath(root,relative))
        startswith(path,abspath(root)*"/") || error("Source image escaped project")
        actual[relative]=bytes2hex(SHA.sha256(read(path)))
        actual[relative]==digest || error("Cold source changed: $relative")
    end
    return actual
end
function _load_definitions!(root)
    native=joinpath(root,"benchmark","native_downstream")
    Base.include(Main,joinpath(native,"load_newborn_binding_experiment.jl"))
    for (name,file) in (
        (:GraphRowProjection,"graph_row_projection.jl"),
        (:ExecutionGroupLookup,"execution_group_lookup.jl"),
        (:ExecutionGroupEpochLookup,"execution_group_epoch_lookup.jl"),
        (:TrustedExecutionGroupIndex,"trusted_execution_group_index.jl"),
        (:TypedOutputPreparation,"typed_output_preparation.jl"),
        (:XPPreparedBatchTiming,"xp_prepared_batch_timing.jl"),
        (:XPDispatchRefreshMeasurements,"xp_dispatch_refresh_measurements.jl"),
        (:PBPreparationScaling,"pb_preparation_scaling.jl"),
        (:XPPreparationScaling,"xp_preparation_scaling.jl"),
    )
        isdefined(Main,name) || Base.include(Main,joinpath(native,file))
    end
    return nothing
end
Base.@nospecializeinfer @noinline function _register(kind,steps,nobjects,profile,outputs,seed)
    @nospecialize outputs
    if kind===:pb
        return Base.invokelatest(getfield(Main,:PBPreparationScaling).register_pb_preparation_case!,
            :cold_pb_preparation_pilot;steps,nobjects,outputs)
    end
    return Base.invokelatest(getfield(Main,:XPPreparationScaling).register_xp_preparation_scaling_case!,
        :cold_xp_preparation_pilot;days=steps,profile,outputs,seed)
end
Base.@nospecializeinfer @noinline function _construct(spec,variant)
    @nospecialize spec variant
    return Base.invokelatest(spec.construct,spec.config,variant)
end
Base.@nospecializeinfer @noinline function _prepare(spec,fixture,variant)
    @nospecialize spec fixture variant
    return Base.invokelatest(spec.prepare,fixture,spec.config,variant)
end
Base.@nospecializeinfer @noinline function _lower(spec,simulation,fixture,variant)
    @nospecialize spec simulation fixture variant
    result=Base.invokelatest(spec.lower,simulation,fixture,spec.config,variant)
    result===nothing || error("Cold preparation case unexpectedly enabled a numerical backend")
    return nothing
end
Base.@nospecializeinfer @noinline function _step!(simulation)
    @nospecialize simulation
    Base.invokelatest(getfield(Main,:PlantSimEngine).step!,simulation)
    return nothing
end
Base.@nospecializeinfer @noinline function _remaining!(simulation,count)
    @nospecialize simulation
    Base.invokelatest(getfield(Main,:PlantSimEngine).continue!,simulation;steps=count)
    return nothing
end
Base.@nospecializeinfer @noinline function _model_case(spec,variant,kind,arm,steps,stage_path)
    @nospecialize spec variant
    phases=Dict{Symbol,Any}()
    _stage(stage_path,kind,arm,"before_construction")
    measured=_timed(_construct,spec,variant)
    fixture=measured.value; phases[:construction]=_phase(measured)
    _stage(stage_path,kind,arm,"before_pse_preparation")
    measured=_timed(_prepare,spec,fixture,variant)
    simulation=measured.value; phases[:pse_preparation]=_phase(measured)
    getfield(simulation,:current_step)==0 || error("Preparation executed scientific steps")
    _stage(stage_path,kind,arm,"before_backend_lowering")
    measured=_timed(_lower,spec,simulation,fixture,variant)
    phases[:backend_lowering]=_phase(measured)
    _stage(stage_path,kind,arm,"before_first_execution")
    measured=_timed(_step!,simulation)
    phases[:first_execution]=_phase(measured)
    getfield(simulation,:current_step)==1 || error("First execution did not advance one step")
    _stage(stage_path,kind,arm,"before_remaining_execution")
    measured=_timed(_remaining!,simulation,steps-1)
    phases[:remaining_execution]=_phase(measured)
    getfield(simulation,:current_step)==steps || error("Incomplete cold scientific trajectory")
    finished_ns=time_ns()
    _stage(stage_path,kind,arm,"after_scientific_execution")
    return (;fixture,simulation,phases,finished_ns)
end
Base.@nospecializeinfer @noinline function _observe(bundle,spec,variant)
    @nospecialize bundle spec variant
    SHA=getfield(Main,:SHA)
    observed=Base.invokelatest(spec.fingerprint,bundle.simulation,bundle.fixture,spec.config)
    coverage=Base.invokelatest(spec.coverage,bundle.simulation,nothing,bundle.fixture,spec.config,variant)
    work=Base.invokelatest(spec.work,bundle.simulation,bundle.fixture,spec.config)
    return (digest=bytes2hex(SHA.sha256(repr(observed))),snapshot=observed,coverage,work)
end
Base.@nospecializeinfer @noinline function _record(bundle,observation,spec,arm,temperature)
    @nospecialize bundle observation spec
    return merge(observation,(;arm,temperature,config=spec.config,phases=bundle.phases,
        complete_seconds=sum(p.seconds for p in values(bundle.phases)),
        complete_allocated_bytes=sum(p.allocated_bytes for p in values(bundle.phases)),
        complete_gc_seconds=sum(p.gc_seconds for p in values(bundle.phases)),
        complete_cost_scope=:fresh_construction_enablement_pse_preparation_lowering_first_and_remaining_execution,
        diagnostic_timing=:after_all_five_model_phases,
        scientific_executor=:ordinary_PSE_with_original_downstream_models))
end
Base.@nospecializeinfer @noinline function _parity(first_bundle,warm_bundle,first_observed,warm_observed)
    @nospecialize first_bundle warm_bundle first_observed warm_observed
    isequal(first_observed.snapshot,warm_observed.snapshot) || error("Cold/warm fresh scientific state/history/types/RNG differs")
    first_observed.digest==warm_observed.digest || error("Cold/warm digest differs")
    isequal(first_observed.work,warm_observed.work) || error("Cold/warm actual work differs")
    first_bundle.fixture.model !== warm_bundle.fixture.model || error("Warm companion reused the first model")
    F=getfield(Main,:DirectPlannerFixtures)
    a=Base.invokelatest(F.identities,first_bundle.fixture.model)
    b=Base.invokelatest(F.identities,warm_bundle.fixture.model)
    keys(a.statuses)==keys(b.statuses) && keys(a.references)==keys(b.references) || error("Cold/warm status schemas differ")
    all(key->typeof(a.statuses[key])===typeof(b.statuses[key]),keys(a.statuses)) || error("Cold/warm canonical Status types differ")
    all(key->typeof(a.references[key])===typeof(b.references[key]),keys(a.references)) || error("Cold/warm canonical Ref types differ")
    PSE=getfield(Main,:PlantSimEngine)
    all(key->!(a.statuses[key] isa PSE.Status) || a.statuses[key] !== b.statuses[key],keys(a.statuses)) || error("Independent instances share a canonical Status")
    all(key->a.references[key] !== b.references[key],keys(a.references)) || error("Independent instances share canonical Ref cells")
    return (passed=true,full_snapshot_rng_history_types_equal=true,work_equal=true,
        independent_models=true,canonical_status_types_equal=true,canonical_reference_types_equal=true,
        cross_instance_statuses_disjoint=true,cross_instance_canonical_references_disjoint=true,
        reference_transition_scope=:separate_per_step_feature_gates_no_preexecution_cold_probe)
end

"""One model-first-use arm in a distinct, previously unrun Kaimon worker.

The caller captures entry_started_ns BEFORE including this driver and supplies
its @timed include result as bootstrap_measurement. Normal OS/package/disk caches
remain available. Kaimon process startup/handshake is outside this Julia clock.
The model-first-use result is followed by ONE freshly constructed warm instance;
that companion is not an independent steady-state screen or a continuation.
"""
Base.@nospecializeinfer @noinline function run_preparation_scaling_cold_case(
    kind::Symbol,arm::Symbol;freshness,expected_source_hashes,output_path,
    entry_started_ns,bootstrap_measurement,root=pwd(),steps::Int=2,nobjects::Int=2,
    profile::Symbol=:accelerated,outputs=:none,seed::Int=1,
    expected_project=joinpath(root,"Project.toml"),expected_digest=nothing)
    kind in (:pb,:xp) && arm in COLD_ARMS || error("Choose PB/XP and ordinary_a/bounded_graph/typed_graph")
    steps>=2 && nobjects>0 || error("Cold pilot requires at least two steps and positive PB objects")
    all(name->hasproperty(freshness,name) && getproperty(freshness,name)===true,
        (:new_process,:no_prior_case_execution,:no_prior_ir_probe)) || error("Missing fresh-worker attestation")
    hasproperty(freshness,:pid) && freshness.pid==getpid() || error("Wrong cold PID")
    hasproperty(freshness,:previous_pid) && freshness.previous_pid==getpid() && error("Restart reused the same PID")
    hasproperty(freshness,:prior_pids) && getpid() in freshness.prior_pids && error("PID already appears in cold cohort")
    iszero(COLD_COUNT[]) || error("Only one first-use case per fresh worker")
    for name in (:DirectPlannerMeasurements,:NativeDownstreamMeasurements,:NativePBDriver,:NativeXPDriver,
        :PBPreparationScaling,:XPPreparationScaling)
        isdefined(Main,name) && error("Experimental/scientific fixture definitions already loaded: $name")
    end
    entry_started_ns<=time_ns() || error("Invalid caller clock")
    COLD_COUNT[]+=1
    preimport=_preimport()
    bootstrap_phase=_phase(bootstrap_measurement)
    stage_path=output_path*".pid$(getpid()).stages.tsv"
    setup=Dict{Symbol,Any}()
    _stage(stage_path,kind,arm,"before_package_imports")
    measured=_timed(_import_packages!,root);setup[:package_imports]=_phase(measured)
    PSE=getfield(Main,:PlantSimEngine)
    realpath(Base.pathof(PSE))==realpath(joinpath(root,"src","PlantSimEngine.jl")) || error("Unexpected PSE source")
    realpath(Base.active_project())==realpath(expected_project) || error("Unexpected active project")
    realpath(DRIVER_PATH)==realpath(joinpath(root,"benchmark","native_downstream","preparation_scaling_cold_case.jl")) || error("Copy the frozen driver into the active source cohort before cold runs")
    image=Base.invokelatest(_check_image,root,expected_source_hashes)
    _stage(stage_path,kind,arm,"before_driver_load")
    measured=_timed(_load_definitions!,root);setup[:driver_load]=_phase(measured)
    H=getfield(Main,:DirectPlannerMeasurements);M=getfield(Main,:NativeDownstreamMeasurements)
    iszero(H.COLD_COUNT[]) && iszero(M.MEASUREMENT_COUNT[]) && isempty(M.FIRST_USE_RECORDS) || error("A harness case already ran")
    H.COLD_COUNT[]+=1;M.MEASUREMENT_COUNT[]+=1
    _stage(stage_path,kind,arm,"before_case_registration")
    measured=_timed(_register,kind,steps,nobjects,profile,outputs,seed)
    spec=measured.value;setup[:case_registration]=_phase(measured)
    variant=only(filter(value->value.name===arm,spec.variants))
    first_bundle=Base.invokelatest(_model_case,spec,variant,kind,arm,steps,stage_path)
    first_use_elapsed_seconds=(first_bundle.finished_ns-entry_started_ns)/1e9
    first_observed=Base.invokelatest(_observe,first_bundle,spec,variant)
    expected_digest===nothing || first_observed.digest==expected_digest || error("First-use scientific oracle differs")
    first_record=Base.invokelatest(_record,first_bundle,first_observed,spec,arm,:first_use)
    _stage(stage_path,kind,arm,"before_fresh_warm_companion")
    warm_bundle=Base.invokelatest(_model_case,spec,variant,kind,arm,steps,stage_path)
    warm_observed=Base.invokelatest(_observe,warm_bundle,spec,variant)
    warm_record=Base.invokelatest(_record,warm_bundle,warm_observed,spec,arm,:warm_fresh_instance_after_first_case_and_diagnostics)
    parity=Base.invokelatest(_parity,first_bundle,warm_bundle,first_observed,warm_observed)
    Base.invokelatest(_check_image,root,expected_source_hashes)==image || error("Cold source changed during case")
    provenance=Base.invokelatest() do
        Main.NativeDownstreamMeasurements.process_provenance(
            packages=(Main.PlantSimEngine,Main.PlantBiophysics,Main.XPalm,Main.PlantGeom))
    end
    accounted=bootstrap_phase.seconds+sum(p.seconds for p in values(setup))+first_record.complete_seconds
    first_use_elapsed_seconds+1e-6>=accounted || error("Inclusive cold clock is smaller than accounted phases")
    result=(protocol=PROTOCOL,kind,arm,
        worker=(pid=getpid(),julia=string(VERSION),project=Base.active_project(),freshness,preimport),
        bootstrap_phase,setup_phases=setup,record=first_record,warm_companion=warm_record,parity,
        first_use_elapsed_seconds,accounted_first_use_phase_seconds=accounted,
        unassigned_first_use_overhead_seconds=max(0.0,first_use_elapsed_seconds-accounted),
        first_use_clock_scope=:caller_before_driver_include_through_first_scientific_completion_excludes_Kaimon_startup,
        first_use_phase_accounting=:bootstrap_plus_imports_definitions_registration_and_five_model_phases,
        setup_scope=(package_imports=:common_PSE_PB_XP_PlantGeom_union_same_for_every_kind_and_arm,
            driver_load=:experimental_definitions_and_model_descriptors_no_scientific_kernel_execution,
            case_registration=:charged_inclusive_including_XP_weather_IO_and_registration_compilation,
            registered_warm_config_forcing_exclusion_overridden_by_charged_cold_registration=true),
        cache_state=(new_process_attested=true,normal_disk_and_package_caches_retained=true,
            environment_setup_outside_case=true,package_preload_facts_recorded=true),
        source_image=image,source_image_verified_before_after=true,provenance,
        warm_scope=:one_new_independent_model_after_first_case_and_diagnostics_not_a_reused_timeline_or_steady_state_trial)
    mkpath(dirname(abspath(output_path)))
    open(output_path,"w") do io
        Base.invokelatest(PSE.JSON.print,io,result,2)
    end
    _stage(stage_path,kind,arm,"after_all_diagnostics_and_write")
    return (protocol=PROTOCOL,kind,arm,pid=getpid(),output_path,digest=first_record.digest,
        model_first_use_seconds=first_record.complete_seconds,first_use_elapsed_seconds,
        warm_fresh_model_seconds=warm_record.complete_seconds,source_files_verified=length(image),parity=parity.passed)
end

end # module
