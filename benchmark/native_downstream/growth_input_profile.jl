module GrowthInputProfile

using Profile, PlantSimEngine
const PSE=PlantSimEngine
const H=Main.DirectPlannerMeasurements
const F=Main.DirectPlannerFixtures
const G=Main.DirectPlannerGrowthProfile
export profile_growth_inputs, profile_growth_input_allocations, classifier_checks

# Classify concrete callees rather than treating the complete input-refresh
# parent as selector work. First matching frame is the exclusive leafward tag;
# inclusive tags remain a separate, explicitly overlapping view.
const CATEGORY_FUNCTIONS=(
    selector_source=("_dependency_object_ids","_cached_dependency_object_ids",
        "_resolve_object_ids","_filter_many_input_sources_by_writer!",
        "_matching_input_source_applications","_potential_input_source_applications",
        "_final_canonical_source_application","_final_many_source_applications",
        "_application_writes_object_variable","_selector_matches"),
    carrier_wiring=("_input_carrier","_stream_only_initial_carrier","_ref_vector_carrier",
        "_share_many_input_binding!","_shared_many_input_binding",
        "_model_input_status_reference","_wire_model_input_carriers!"),
    app_schema=("_input_schema","_model_input_names"),
    default_schema=("_input_default_values",),
    default_target_lookup=("_status_preparation_for_object!","_model_object_status_for_preparation"),
    defaults_status=("_prepare_model_input_defaults!","_prepare_model_input_statuses_batched!",
        "_status_recipe","_apply_status_recipes!",
        "_materialize_status_value","_finish_status_recipe","_CanonicalStatusRecipe",
        "_status_with_reference","_status_with_default"),
    validation=("_validate_model_required_inputs!","_validate_model_input_source!",
        "_validate_policy_instance","_bound_model_inputs"),
    membership_index=("_append_added_many_sources!","_update_structural_many_sources!",
        "_index_dynamic_input_binding","_many_input_binding_cache",
        "_union_selector_candidates!","_queue_shared_many"),
    binding_assembly=("_compile_added_consumer_bindings!","_push_model_input_binding!",
        "_model_selector_policy","_carrier_hint"),
)

function _category(function_name)
    (function_name=="inputs_" || endswith(function_name,".inputs_") ||
        occursin("#inputs_#",function_name)) && return :app_schema
    for (category,names) in pairs(CATEGORY_FUNCTIONS)
        any(name->occursin(name,function_name),names) && return category
    end
    return :other
end
function _classify(functions)
    targeted=any(name->occursin("_targeted_new_object_call_targets",name),functions)
    global_refresh=any(name->occursin("_extend_compiled_scene",name),functions)
    scope=targeted && global_refresh ? :targeted_and_global : targeted ?
        :targeted_newborn : global_refresh ? :global_refresh : :other_execution
    # Output-default assembly shares recipe helpers with input preparation.
    # Keep it separate to avoid misattributing that parent phase to inputs.
    output_preparation=any(name->occursin("_prepare_model_output_statuses",name),functions)
    input_path=any(functions) do name
        any(prefix->occursin(prefix,name), ("_compile_added_consumer_bindings!",
            "_push_model_input_binding!","_prepare_model_input_statuses_batched!",
            "_prepare_model_input_defaults!","_wire_model_input_carriers!",
            "_validate_model_required_inputs!","_model_input_status_reference",
            "_append_added_many_sources!","_index_dynamic_input_binding",
            "_update_structural_many_sources!"))
    end
    categories=Symbol[]
    exclusive=:other
    for function_name in functions
        category=_category(function_name)
        category===:other && continue
        if output_preparation && category in (:app_schema,:default_schema,:default_target_lookup,:defaults_status)
            category=:output_status_preparation
        elseif !input_path && category in (:selector_source,:membership_index,:binding_assembly)
            category=:other_dependency_metadata
        end
        category in categories || push!(categories,category)
        exclusive===:other && (exclusive=category)
    end
    return (;scope,exclusive,inclusive=categories,input_path)
end

function classifier_checks()
    a=_classify(["_resolve_object_ids","_push_model_input_binding!","_targeted_new_object_call_targets"])
    a.scope===:targeted_newborn && a.exclusive===:selector_source || error("Selector classification")
    b=_classify(["_ref_vector_carrier","_input_carrier","_extend_compiled_scene"])
    b.scope===:global_refresh && b.exclusive===:carrier_wiring || error("Carrier classification")
    c=_classify(["_input_schema","_prepare_model_input_statuses_batched!","_extend_compiled_scene"])
    c.exclusive===:app_schema && :defaults_status in c.inclusive || error("Schema/default classification")
    d=_classify(["_apply_status_recipes!","_prepare_model_output_statuses_batched!","_extend_compiled_scene"])
    d.exclusive===:output_status_preparation || error("Output/input separation")
    e=_classify(["_validate_model_required_inputs!","_extend_compiled_scene"])
    e.exclusive===:validation || error("Validation classification")
    f=_classify(["_status_preparation_for_object!","_prepare_model_input_statuses_batched!","_extend_compiled_scene"])
    f.exclusive===:default_target_lookup || error("Default target lookup classification")
    _category("environment_inputs_")===:other || error("Environment schema misclassified")
    _category("inputs_")===:app_schema || error("Model schema classification")
    return (;passed=true,synthetic_cases=8,scientific_kernel_execution=false)
end

_key(scope,category)=string(scope,"/",category)
function _increment!(dictionary,key,count=1)
    dictionary[key]=get(dictionary,key,0)+count
    return nothing
end

Base.@nospecializeinfer @noinline function _cpu_summary(;data=Profile.fetch())
    isempty(data) || Profile.has_meta(data) || error("Julia1.13 metadata required")
    lookup=Profile.getdict(data)
    source_root=joinpath(pkgdir(PSE),"src")
    exclusive=Dict{String,Int}();inclusive=Dict{String,Int}()
    callers=Dict{Tuple{String,String,Int},Int}()
    selected=active=total=unresolved=0;last_end=0
    for finish in eachindex(data)
        finish>=6 || continue
        data[finish]==0 && data[finish-1]==0 || continue
        data[finish-2] in (UInt(1),UInt(2),UInt(3)) || continue
        data[finish-3]!=0 && data[finish-4]!=0 && data[finish-5]!=0 || continue
        total+=1
        first_ip,final_ip=last_end+1,finish-6;last_end=finish
        data[finish-2]==UInt(2) && continue
        active+=1
        names=String[];rows=Tuple{String,String,Int}[];matches=false
        for index in first_ip:final_ip
            ip=data[index];iszero(ip) && continue
            frames=get(lookup,ip,nothing)
            if frames===nothing
                unresolved+=1;continue
            end
            for frame in frames
                frame.from_c && continue
                name,file=String(frame.func),String(frame.file)
                push!(names,name);push!(rows,(name,file,Int(frame.line)))
                matches|=occursin("PlantSimEngine",file)
            end
        end
        matches || continue
        selected+=1
        tag=_classify(names)
        _increment!(exclusive,_key(tag.scope,tag.exclusive))
        for category in tag.inclusive
            _increment!(inclusive,_key(tag.scope,category))
        end
        for row in Set(rows)
            startswith(row[2],source_root) || continue
            _increment!(callers,row)
        end
    end
    ordered=sort!(collect(keys(callers));by=key->(-callers[key],key[2],key[1],key[3]))
    return (total,active,selected,unresolved_ips=unresolved,trailing_raw_ips=length(data)-last_end,
        exclusive_stack_tags=exclusive,inclusive_overlapping_tags=inclusive,
        functions=[(function_name=k[1],file=k[2],line=k[3],category=_category(k[1]),inclusive=callers[k])
            for k in Iterators.take(ordered,40)],
        interpretation=:coarse_stack_classification_not_exact_disjoint_phase_elapsed_times)
end

Base.@nospecializeinfer @noinline function _allocation_summary(results,sample_rate,max_records)
    @nospecialize results
    length(results.allocs)<=max_records || error("Allocation record budget exceeded; lower sample rate")
    counts=Dict{String,Int}();bytes=Dict{String,Int}()
    inclusive=Dict{String,Int}();types=Dict{Tuple{String,String},Tuple{Int,Int}}()
    sites=Dict{Tuple{String,String,String,String,Int},Tuple{Int,Int}}()
    previews=Dict{Tuple{String,String,String,String,Int},Any}()
    source_root=joinpath(pkgdir(PSE),"src")
    selected=selected_bytes=0
    for allocation in results.allocs
        names=String[];matches=false;source_frames=Any[]
        for frame in allocation.stacktrace
            frame.from_c && continue
            name,file=String(frame.func),String(frame.file)
            push!(names,name)
            matches|=occursin("PlantSimEngine",file)
            if startswith(file,source_root)
                push!(source_frames,(function_name=name,file,line=Int(frame.line)))
            end
        end
        matches || continue
        selected+=1;selected_bytes+=allocation.size
        tag=_classify(names);key=_key(tag.scope,tag.exclusive)
        _increment!(counts,key);_increment!(bytes,key,allocation.size)
        for category in tag.inclusive
            _increment!(inclusive,_key(tag.scope,category),allocation.size)
        end
        # Never render type parameters or a StackFrame/MethodInstance. Group by
        # broad typename only; this avoids the earlier huge-signature printer.
        type_name=allocation.type isa DataType ? string(nameof(allocation.type)) :
            string(nameof(typeof(allocation.type)))
        type_key=(key,type_name);old=get(types,type_key,(0,0))
        types[type_key]=(old[1]+1,old[2]+allocation.size)
        site=isempty(source_frames) ?
            (function_name="no_PSE_src_frame",file="",line=0) : first(source_frames)
        site_key=(key,type_name,site.function_name,site.file,site.line)
        old_site=get(sites,site_key,(0,0))
        sites[site_key]=(old_site[1]+1,old_site[2]+allocation.size)
        if !haskey(previews,site_key)
            previews[site_key]=source_frames[1:min(length(source_frames),8)]
        end
    end
    ordered=sort!(collect(keys(types));by=key->(-types[key][2],key))
    site_order=sort!(collect(keys(sites));by=key->(-sites[key][2],key))
    return (recorded=length(results.allocs),selected,sampled_bytes=selected_bytes,sample_rate,
        exclusive_sampled_counts=counts,exclusive_sampled_bytes=bytes,
        inclusive_overlapping_sampled_bytes=inclusive,
        estimated_exclusive_bytes=Dict(k=>v/sample_rate for (k,v) in bytes),
        top_types=[(stack_tag=k[1],broad_type=k[2],sampled_count=types[k][1],sampled_bytes=types[k][2])
            for k in Iterators.take(ordered,32)],
        top_allocation_sites=[(stack_tag=k[1],broad_type=k[2],function_name=k[3],file=k[4],line=k[5],
            sampled_count=sites[k][1],sampled_bytes=sites[k][2],PSE_source_stack=previews[k])
            for k in Iterators.take(site_order,48)],
        site_scope=:nearest_leafward_PSE_src_frame_with_bounded_source_stack_no_type_parameters,
        interpretation=:sampled_allocation_bytes_and_rate_estimates_not_exact_phase_allocations)
end

Base.@nospecializeinfer @noinline function _sample_cpu!(states,steps)
    @nospecialize states
    Profile.@profile Base.invokelatest(G._execute_states!,states,steps)
    return nothing
end
Base.@nospecializeinfer @noinline function _sample_allocations!(states,steps,rate)
    @nospecialize states
    Profile.Allocs.@profile sample_rate=rate Base.invokelatest(G._execute_states!,states,steps)
    return nothing
end
Base.@nospecializeinfer @noinline function _states(kind,arm,config,repetitions)
    @nospecialize config
    states=Any[];identities=Any[]
    for _ in 1:repetitions
        state=Base.invokelatest(G._state,kind,arm,config)
        push!(identities,Base.invokelatest(F.identities,state[:fixture].model))
        push!(states,state)
    end
    return (;states,identities)
end
Base.@nospecializeinfer @noinline function _verify(bundle,kind,arm,oracle,old_oracle,new_oracle)
    @nospecialize bundle oracle old_oracle new_oracle
    for (state,before) in zip(bundle.states,bundle.identities)
        observed=Base.invokelatest(G._observation,state,kind,arm)
        observed.digest==oracle.digest || error("Profile changed science/history/topology/RNG")
        observed.work==oracle.work || error("Profile changed scientific work")
        after=Base.invokelatest(F.identities,state[:fixture].model)
        F.same_identity_transitions(old_oracle,before,new_oracle,after) ||
            error("Profile changed canonical identity transitions")
    end
    return (;passed=true,cases=length(bundle.states),digest=oracle.digest,work=oracle.work,
        canonical_identity_transitions_match=true)
end

"""Opt-in baseline CPU/allocations sub-attribution; no core method changes.

Use after the existing direct-planner loader. CPU and allocation profiling run
separately on fresh independently constructed scenes after one unprofiled warm
oracle. Definitions alone execute no science. Requested timings include profiler
overhead/JIT/GC and cannot establish candidate speed. Framework counters are a
separate warmed companion, and stack tags remain approximate phase attribution.
"""
Base.@nospecializeinfer @noinline function profile_growth_inputs(;
    kind::Symbol=:xp,arm::Symbol=:reference_executor,steps=2,repetitions::Int=3,
    allocation_sample_rate=0.01,cpu_delay=0.0005,max_allocation_records=50_000,
    nobjects=128,additions=3,outputs=:none,progress_path=nothing,expected_digest=nothing,
    include_framework=true,run_cpu=true)
    0<allocation_sample_rate<=1 || error("Sample rate must be in (0,1]")
    repetitions>0 && steps>0 || error("Positive repetitions/steps required")
    classifier_checks()
    config=H.construct_config(kind;steps,nobjects,additions,outputs)
    H._stage(progress_path,kind,arm,"before_input_profile_oracle")
    warm=Base.invokelatest(G._state,kind,arm,config)
    old_oracle=Base.invokelatest(F.identities,warm[:fixture].model)
    Base.invokelatest(G._execute_states!,Any[warm],steps)
    new_oracle=Base.invokelatest(F.identities,warm[:fixture].model)
    oracle=Base.invokelatest(G._observation,warm,kind,arm)
    expected_digest===nothing || expected_digest==oracle.digest || error("Unexpected oracle digest")
    cpu=cpu_measurement=cpu_check=nothing
    if run_cpu
        cpu_bundle=Base.invokelatest(_states,kind,arm,config,repetitions)
        Profile.init(n=2^20,delay=cpu_delay);Profile.clear()
        H._stage(progress_path,kind,arm,"before_input_CPU_profile")
        cpu_measurement=H._timed(_sample_cpu!,cpu_bundle.states,steps)
        H._stage(progress_path,kind,arm,"after_input_CPU_profile")
        cpu=Base.invokelatest(_cpu_summary)
        cpu_check=Base.invokelatest(_verify,cpu_bundle,kind,arm,oracle,old_oracle,new_oracle)
    end
    allocation_bundle=Base.invokelatest(_states,kind,arm,config,repetitions)
    Profile.Allocs.clear()
    H._stage(progress_path,kind,arm,"before_input_allocation_profile")
    allocation_measurement=H._timed(_sample_allocations!,allocation_bundle.states,steps,allocation_sample_rate)
    H._stage(progress_path,kind,arm,"after_input_allocation_profile")
    allocations=Base.invokelatest(_allocation_summary,Profile.Allocs.fetch(),
        allocation_sample_rate,max_allocation_records)
    allocation_check=Base.invokelatest(_verify,allocation_bundle,kind,arm,oracle,old_oracle,new_oracle)
    Profile.Allocs.clear()
    framework=include_framework ? Base.invokelatest(G.framework_growth_companion,kind,arm;
        steps,nobjects,additions,outputs,expected_digest=oracle.digest) : nothing
    H._stage(progress_path,kind,arm,"after_input_profile_diagnostics")
    return (;passed=true,kind,arm,config,repetitions,pid=getpid(),julia=string(VERSION),
        digest=oracle.digest,work=oracle.work,cpu,allocations,cpu_check,allocation_check,
        cpu_measurement=cpu_measurement===nothing ? nothing : H._phase(cpu_measurement),
        allocation_measurement=H._phase(allocation_measurement),
        framework,benchmark_claim=false,core_methods_changed=false,
        interpretation=:bounded_opt_in_sampling_before_any_growth_optimization)
end

"""Allocation-site companion with no second CPU run or mandatory framework pass."""
profile_growth_input_allocations(;include_framework=false,kwargs...)=
    profile_growth_inputs(;kwargs...,include_framework,run_cpu=false)

end # module
