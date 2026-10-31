module XPGrowthAttribution

using Profile, SHA, PlantSimEngine
const PSE = PlantSimEngine
const H = Main.DirectPlannerMeasurements
const F = Main.DirectPlannerFixtures
const NBM = Main.NewbornBindingMeasurements
const SM = Main.NewbornBindingSequenceMeasurements
const CR = Main.CompiledRegionsExperiment
const M = Main.NativeDownstreamMeasurements

export profile_xp_growth_attribution, profile_xp_preparation,
    xp_framework_attribution, classifier_checks

# Names, paths and source lines only: never stringify MethodInstances, full
# concrete types, scientific values, or Profile's potentially huge signatures.
const CATEGORY_FUNCTIONS = (
    binding_layout_guard=("_layout_matches",),
    binding_header_guard=("_same_header",),
    binding_singleton_guard=("_singleton_local_member",),
    binding_local_membership_guard=("_live_local_member",),
    binding_ownership_guard=("_local_owner_proof",),
    binding_selector=("_dependency_object_ids", "_cached_dependency_object_ids",
        "_resolve_object_ids", "_selector_matches", "_filter_many_input_sources_by_writer!"),
    binding_writer_resolution=("_application_writes_object_variable",
        "_matching_input_source_applications", "_potential_input_source_applications",
        "_final_canonical_source_application", "_final_many_source_applications",
        "_final_inferred_output_plans", "_model_output_names"),
    binding_policy=("_model_selector_policy", "_model_policy_from_source_application",
        "_core_default_policy", "_carrier_hint", "_has_stream_only_input_source"),
    binding_carrier=("_input_carrier", "_stream_only_initial_carrier",
        "_ref_vector_carrier", "_status_ref_or_nothing", "_shared_many_input_binding",
        "_share_many_input_binding!", "_wire_model_input_carriers!",
        "_model_input_status_reference"),
    binding_instrumentation=("_record_success!", "_record_input_execution!",
        "_newborn_consumer!"),
    binding_sequence_dispatch=("_dispatch_plan!", "_execute_prepared_instruction!",
        "_try_newborn_binding_instruction!"),
    binding_consumer_dispatch=("_try_newborn_binding_sequence!",
        "_compile_added_consumer_bindings!", "_push_model_input_binding"),
    declaration_certificate=("_declaration_proof!", "_prepare_newborn_binding_program!",
        "_binding_program_prepared!", "_build_sequence"),
    input_status_defaults=("_prepare_model_input_statuses_batched!",
        "_prepare_model_input_defaults!", "_input_default_values", "_input_schema"),
    status_recipe=("_apply_status_recipes!", "_CanonicalStatusRecipe",
        "_finish_status_recipe", "_status_with_reference", "_status_with_default",
        "_status_preparation_for_object!", "_model_object_status_for_preparation"),
    output_status=("_prepare_model_output_statuses",),
    status_view=("_prepare_compiled_model_status_view", "_compile_model_status_view",
        "_extend_model_status_views", "_preserve_model_status_view"),
    environment=("_targeted_call_environment_bindings", "_refresh_environment_bindings",
        "refresh_environment_bindings!", "_compile_environment", "_model_environment_for_binding",
        "_model_execution_batch_environment", "sample_environment"),
    execution_group_refresh=("_refresh_model_execution_plan", "_refresh_model_execution_group",
        "_try_refresh_model_execution_plan_for_pure_addition!", "_compiled_execution_batches"),
    schedule_refresh=("_refresh_application_schedule", "_refresh_model_schedule",
        "_extend_application_schedule", "_new_application_targets"),
    distributed_writer_refresh=("_refresh_model_distributed_outputs",
        "_incremental_distributed_output_addition!", "_validate_model_writer"),
    membership_index=("_append_added_many_sources!", "_update_structural_many_sources!",
        "_index_dynamic_input_binding", "_many_input_binding_cache",
        "_union_selector_candidates!", "_queue_shared_many"),
    validation=("_validate_model_required_inputs!", "_validate_model_input_source!",
        "_validate_policy_instance", "_bound_model_inputs"),
    logical_refresh=("_extend_compiled_scene", "_refresh_simulation_runtime!"),
    targeted_preparation=("_targeted_new_object_call_targets",),
    temporal_publication=("_materialize_model_inputs!", "_model_publish_runtime_outputs!",
        "_publish_model_outputs", "_append_model_output"),
)

_inside(file, root) = startswith(replace(file, '\\' => '/'), replace(root, '\\' => '/'))
_contains(functions, needle) = any(name -> occursin(needle, name), functions)

function _category(row, scientific_roots, declaration_stack)
    name, file = row.function_name, row.file
    lower = lowercase(name)
    if row.from_c
        (occursin("gc_collect", lower) || occursin("gc_sweep", lower) ||
            occursin("gc_mark", lower)) && return :gc_runtime
        ((occursin("gc_", lower) && occursin("alloc", lower)) || occursin("jl_alloc", lower) ||
            occursin("malloc", lower)) && return :allocation_runtime
        (occursin("apply_generic", lower) || occursin("jl_invoke", lower)) &&
            return :dynamic_dispatch_runtime
        return :other
    end
    (occursin("/Compiler/src/", file) || occursin("/compiler/", file)) &&
        return :compiler_jit
    for (category, names) in pairs(CATEGORY_FUNCTIONS)
        any(needle -> occursin(needle, name), names) && return category
    end
    if name in ("inputs_", "outputs_") || occursin("#inputs_#", name) || occursin("#outputs_#", name)
        return :port_declaration
    end
    if endswith(file, "newborn_binding_program.jl") || endswith(file, "newborn_binding_sequence.jl")
        return name in ("_count!", "_miss!") ? :binding_instrumentation : :binding_metadata_other
    end
    any(root -> _inside(file, root), scientific_roots) &&
        return declaration_stack ? :port_declaration : :scientific_model
    occursin("/PlantSimEngine/", file) && return :framework_other
    return :other
end

function _classify(rows, scientific_roots)
    functions = [row.function_name for row in rows if !row.from_c]
    targeted = _contains(functions, "_targeted_new_object_call_targets")
    global_refresh = _contains(functions, "_extend_compiled_scene")
    preparation = _contains(functions, "_prepare_only!")
    scope = targeted && global_refresh ? :targeted_and_global :
        targeted ? :targeted_newborn : global_refresh ? :global_refresh :
        preparation ? :initial_preparation : :other_execution
    declarations = any(name -> name in ("inputs_", "outputs_") ||
        occursin("#inputs_#", name) || occursin("#outputs_#", name), functions)
    inclusive = Symbol[]
    exclusive = :other
    for row in rows
        category = _category(row, scientific_roots, declarations)
        category === :other && continue
        category in inclusive || push!(inclusive, category)
        exclusive === :other && (exclusive = category)
    end
    return (; scope, exclusive, inclusive)
end

function classifier_checks()
    row(name; file="/fixture/PlantSimEngine/src/composite_model/compilation.jl", from_c=false) =
        (function_name=name, file, line=1, from_c)
    a = _classify([row("_same_header"), row("_singleton_local_member"), row("_extend_compiled_scene")], ())
    a.exclusive === :binding_header_guard && :binding_singleton_guard in a.inclusive &&
        a.scope === :global_refresh || error("Nested guard attribution failed")
    b = _classify([row("_local_owner_proof"), row("_targeted_new_object_call_targets")], ())
    b.exclusive === :binding_ownership_guard && b.scope === :targeted_newborn || error("Owner attribution failed")
    c = _classify([row("run!"; file="/fixture/XPalm/src/process.jl"), row("_run_model_execution_batch!")],
        ("/fixture/XPalm/src",))
    c.exclusive === :scientific_model || error("Scientific attribution failed")
    d = _classify([row("_input_carrier"), row("run!"; file="/fixture/XPalm/src/growth.jl")],
        ("/fixture/XPalm/src",))
    d.exclusive === :binding_carrier && :scientific_model in d.inclusive || error("Nested kernel/framework attribution failed")
    e = _classify([row("outputs_"; file="/fixture/XPalm/src/process.jl")], ("/fixture/XPalm/src",))
    e.exclusive === :port_declaration || error("Declaration misclassified as science")
    f = _classify([row("jl_gc_alloc"; file="", from_c=true), row("_layout_matches")], ())
    f.exclusive === :allocation_runtime && :binding_layout_guard in f.inclusive || error("Runtime/guard attribution failed")
    _operation_row(row("profile"; file="/fixture/PlantSimEngine/benchmark/native_downstream/xp_growth_attribution.jl"),
        (), "/fixture/PlantSimEngine/src") && error("Harness wrapper accepted as operation site")
    _operation_row(row("run!"; file="/fixture/XPalm/src/process.jl"),
        ("/fixture/XPalm/src",), "/fixture/PlantSimEngine/src") || error("Scientific operation site omitted")
    return (passed=true, synthetic_cases=8, scientific_kernel_execution=false)
end

_key(tag, category) = string(tag.scope, "/", category)
_increment!(dictionary, key, amount=1) = (dictionary[key] = get(dictionary, key, 0) + amount)

function _scientific_roots()
    driver = getfield(Main, :NativeXPDriver)
    roots = String[joinpath(pkgdir(getfield(driver, :XPalm)), "src")]
    if isdefined(Main, :NativePBDriver)
        pb_driver = getfield(Main, :NativePBDriver)
        isdefined(pb_driver, :PlantBiophysics) &&
            push!(roots, joinpath(pkgdir(getfield(pb_driver, :PlantBiophysics)), "src"))
    end
    return Tuple(unique!(roots))
end

function _operation_row(row, scientific_roots, source_root)
    row.from_c && return false
    return _inside(row.file, source_root) ||
        endswith(row.file, "newborn_binding_program.jl") ||
        endswith(row.file, "newborn_binding_sequence.jl") ||
        any(root -> _inside(row.file, root), scientific_roots)
end

function _site_rows(sites, limit)
    ordered = sort!(collect(keys(sites)); by=key -> (-sites[key], key))
    return [(function_name=k[1], file=k[2], line=k[3], category=k[4], samples=sites[k])
        for k in Iterators.take(ordered, limit)]
end

Base.@nospecializeinfer @noinline function _cpu_summary(data, scientific_roots;
    limit=32, entry_name="_execute!")
    @nospecialize data scientific_roots
    isempty(data) || Profile.has_meta(data) || error("Julia metadata required")
    lookup = Profile.getdict(data)
    exclusive = Dict{String,Int}(); inclusive = Dict{String,Int}()
    operation_exclusive = Dict{String,Int}(); operation_inclusive = Dict{String,Int}()
    functions = Dict{Tuple{String,String,Int},Int}()
    leaf_sites = Dict{Tuple{String,String,Int,Symbol},Int}()
    dispatch_sites = Dict{Tuple{String,String,Int,Symbol},Int}()
    source_root = joinpath(pkgdir(PSE), "src")
    total = active = unresolved = recognized = 0
    operation_samples = dispatch_parent_samples = entry_samples = 0
    last_end = 0
    for finish in eachindex(data)
        finish >= 6 || continue
        data[finish] == 0 && data[finish-1] == 0 || continue
        data[finish-2] in (UInt(1), UInt(2), UInt(3)) || continue
        data[finish-3] != 0 && data[finish-4] != 0 && data[finish-5] != 0 || continue
        total += 1
        first_ip, final_ip = last_end+1, finish-6
        last_end = finish
        data[finish-2] == UInt(2) && continue
        active += 1
        rows = NamedTuple[]
        for index in first_ip:final_ip
            ip = data[index]
            iszero(ip) && continue
            frames = get(lookup, ip, nothing)
            if frames === nothing
                unresolved += 1
                continue
            end
            for frame in frames
                push!(rows, (function_name=String(frame.func), file=String(frame.file),
                    line=Int(frame.line), from_c=frame.from_c))
            end
        end
        tag = _classify(rows, scientific_roots)
        tag.exclusive === :other || (recognized += 1)
        _increment!(exclusive, _key(tag, tag.exclusive))
        for category in tag.inclusive
            _increment!(inclusive, _key(tag, category))
        end
        any(row -> row.function_name == entry_name &&
            endswith(row.file, "xp_growth_attribution.jl"), rows) || continue
        entry_samples += 1
        leaf = findfirst(row -> _operation_row(row, scientific_roots, source_root), rows)
        declarations = any(row -> !row.from_c &&
            (row.function_name in ("inputs_", "outputs_") ||
             occursin("#inputs_#", row.function_name) || occursin("#outputs_#", row.function_name)), rows)
        if leaf !== nothing
            operation_samples += 1
            row = rows[leaf]
            category = _category(row, scientific_roots, declarations)
            _increment!(leaf_sites, (row.function_name, row.file, row.line, category))
            _increment!(operation_exclusive, _key(tag, tag.exclusive))
            for category in tag.inclusive
                _increment!(operation_inclusive, _key(tag, category))
            end
        end
        dispatch = findfirst(row -> row.from_c &&
            _category(row, scientific_roots, declarations) === :dynamic_dispatch_runtime, rows)
        if dispatch !== nothing
            # Source caller above the nearest dynamic-dispatch runtime frame,
            # rather than a generic jl_apply frame or an inclusive harness root.
            for index in (dispatch+1):length(rows)
                row = rows[index]
                _operation_row(row, scientific_roots, source_root) || continue
                category = _category(row, scientific_roots, declarations)
                _increment!(dispatch_sites, (row.function_name, row.file, row.line, category))
                dispatch_parent_samples += 1
                break
            end
        end
        for row in Set(rows)
            category = _category(row, scientific_roots, false)
            category === :other && continue
            _increment!(functions, (row.function_name, row.file, row.line))
        end
    end
    ordered = sort!(collect(keys(functions)); by=key -> (-functions[key], key))
    return (samples_total=total, samples_active=active, samples_recognized=recognized,
        samples_in_profile_entry=entry_samples, samples_outside_profile_entry=active-entry_samples,
        samples_with_operation=operation_samples,
        samples_without_operation=active-operation_samples,
        entry_samples_without_operation=entry_samples-operation_samples,
        samples_with_dynamic_dispatch_operation_parent=dispatch_parent_samples,
        unresolved_ips=unresolved, trailing_raw_ips=length(data)-last_end,
        exclusive_stack_samples=exclusive, inclusive_overlapping_stack_samples=inclusive,
        operation_exclusive_stack_samples=operation_exclusive,
        operation_inclusive_overlapping_stack_samples=operation_inclusive,
        operation_leaf_sites=_site_rows(leaf_sites, 40),
        dynamic_dispatch_parent_sites=_site_rows(dispatch_sites, 32),
        functions=[(function_name=k[1], file=k[2], line=k[3], inclusive=functions[k])
            for k in Iterators.take(ordered, limit)],
        qualification=operation_samples >= 100 ? :coarse_operation_sampling : :sparse_operation_samples_no_stable_share_claim,
        qualification_sample_population=:samples_with_PSE_src_or_scientific_src_or_binding_program_operation,
        stack_category_population=:all_active_samples_and_separately_operation_samples,
        profile_entry=(function_name=entry_name, file_suffix="xp_growth_attribution.jl"),
        operation_site_population=:entry_selected_samples_only,
        inclusive_function_population=:entry_selected_samples_only,
        operation_site_selection=:nearest_leafward_Julia_source_frame_excluding_harness_and_profile_wrappers,
        interpretation=:nearest_recognized_leafward_category_not_exact_or_additive_phase_times)
end

Base.@nospecializeinfer @noinline function _allocation_summary(results, roots, rate, max_records)
    @nospecialize results roots
    length(results.allocs) <= max_records || error("Allocation record budget exceeded; lower sampling rate")
    counts = Dict{String,Int}(); bytes = Dict{String,Int}(); inclusive = Dict{String,Int}()
    sites = Dict{Tuple{String,String,String,String,Int},Tuple{Int,Int}}()
    previews = Dict{Tuple{String,String,String,String,Int},Any}()
    source_root = joinpath(pkgdir(PSE), "src")
    for allocation in results.allocs
        rows = [(function_name=String(frame.func), file=String(frame.file),
            line=Int(frame.line), from_c=frame.from_c) for frame in allocation.stacktrace]
        tag = _classify(rows, roots)
        key = _key(tag, tag.exclusive)
        _increment!(counts, key); _increment!(bytes, key, allocation.size)
        for category in tag.inclusive
            _increment!(inclusive, _key(tag, category), allocation.size)
        end
        broad_type = allocation.type isa DataType ? string(nameof(allocation.type)) :
            string(nameof(typeof(allocation.type)))
        sources = [row for row in rows if !row.from_c &&
            (_inside(row.file, source_root) || endswith(row.file, "newborn_binding_sequence.jl") ||
             endswith(row.file, "newborn_binding_program.jl") || any(root -> _inside(row.file, root), roots))]
        site = isempty(sources) ? (function_name="no_model_or_PSE_source", file="", line=0) : first(sources)
        site_key = (key, broad_type, site.function_name, site.file, site.line)
        previous = get(sites, site_key, (0, 0))
        sites[site_key] = (previous[1]+1, previous[2]+allocation.size)
        haskey(previews, site_key) || (previews[site_key] = sources[1:min(length(sources), 6)])
    end
    ordered = sort!(collect(keys(sites)); by=key -> (-sites[key][2], key))
    return (records=length(results.allocs), sample_rate=rate,
        sampled_bytes=sum(values(bytes); init=0), exclusive_sampled_counts=counts,
        exclusive_sampled_bytes=bytes, inclusive_overlapping_sampled_bytes=inclusive,
        rate_estimated_exclusive_bytes=Dict(key => value/rate for (key,value) in bytes),
        sites=[(stack_tag=k[1], broad_type=k[2], function_name=k[3], file=k[4], line=k[5],
            sampled_count=sites[k][1], sampled_bytes=sites[k][2], source_stack=previews[k])
            for k in Iterators.take(ordered, 40)],
        interpretation=:sampled_allocations_and_rate_estimates_not_exact_phase_allocations)
end

Base.@nospecializeinfer @noinline function _state(arm, config; performance=false)
    @nospecialize config
    constructed = H._timed(NBM._construct_binding_fixture, :xp, config)
    fixture = constructed.value
    prepared = H._timed(SM.prepare_sequence_arm, fixture.model, arm;
        outputs=config.outputs, performance, count_calls=false, details=false)
    return Dict{Symbol,Any}(:fixture=>fixture, :simulation=>prepared.value,
        :phases=>(constructor=H._phase(constructed), preparation=H._phase(prepared)))
end

Base.@nospecializeinfer @noinline function _execute!(states, steps)
    @nospecialize states
    for state in states
        Base.invokelatest(PSE.continue!, state[:simulation]; steps)
    end
    return nothing
end

Base.@nospecializeinfer @noinline function _observe(state, arm;
    instrumented=false, require_newborn=true)
    @nospecialize state
    simulation, fixture = state[:simulation], state[:fixture]
    snapshot = (state=Base.invokelatest(F.snapshot, simulation, :xp),
        scientific_rngs=Base.invokelatest(F.scientific_rngs, simulation.model))
    return (snapshot, digest=bytes2hex(sha256(repr(snapshot))),
        work=Base.invokelatest(CR.downstream_work_report, simulation, fixture.initial_ids),
        coverage=Base.invokelatest(SM.sequence_coverage, simulation, arm, :xp;
            instrumented, details=false, require_newborn))
end

Base.@nospecializeinfer @noinline function _states(arm, config, repetitions)
    @nospecialize config
    states = Any[]; identities = Any[]
    for _ in 1:repetitions
        state = Base.invokelatest(_state, arm, config)
        push!(states, state)
        push!(identities, Base.invokelatest(F.identities, state[:fixture].model))
    end
    return (; states, identities)
end

Base.@nospecializeinfer @noinline function _verify(bundle, arm, oracle, old_oracle, new_oracle;
    instrumented=false)
    @nospecialize bundle oracle old_oracle new_oracle
    evidence = Any[]
    for (state, before) in zip(bundle.states, bundle.identities)
        observed = Base.invokelatest(_observe, state, arm; instrumented)
        isequal(observed.snapshot, oracle.snapshot) || error("Profile changed full science/history/topology/RNG")
        isequal(observed.work, oracle.work) || error("Profile changed scientific work")
        after = Base.invokelatest(F.identities, state[:fixture].model)
        F.same_identity_transitions(old_oracle, before, new_oracle, after) ||
            error("Profile changed canonical identity transitions")
        push!(evidence, (digest=observed.digest, work=observed.work,
            coverage=observed.coverage, phases=state[:phases]))
    end
    return (passed=true, count=length(evidence), canonical_identity_transitions_match=true, cases=evidence)
end

function _counter_delta(before, after)
    return (counts=Dict(name => get(after.counts,name,0)-get(before.counts,name,0)
            for name in union(keys(before.counts),keys(after.counts))),
        elapsed_seconds=Dict(name => get(after.elapsed_seconds,name,0.0)-get(before.elapsed_seconds,name,0.0)
            for name in union(keys(before.elapsed_seconds),keys(after.elapsed_seconds))))
end

"""Fresh performance=true companion; its nested timers are not product timings.

Scientific-kernel time includes framework/call work invoked by a controller.
Do not subtract nested timers to invent disjoint pure-science wall time.
Preparation has separate diagnostic total/JIT/allocation measurements and the
existing initial compiler phase counters. Per-step reports capture growth,
status/view/environment/schedule/execution refresh and current actual work.
"""
Base.@nospecializeinfer @noinline function xp_framework_attribution(arm::Symbol=:bounded_sequence;
    steps::Int=4, seed::Int=1, emission_speed=0.2, outputs=:none,
    expected_digest=nothing, progress_path=nothing, oracle=nothing,
    old_oracle=nothing, new_oracle=nothing)
    config = H.construct_config(:xp; steps, seed, emission_speed, outputs)
    if oracle === nothing
        warm = Base.invokelatest(_state, arm, config)
        old_oracle = Base.invokelatest(F.identities, warm[:fixture].model)
        Base.invokelatest(_execute!, Any[warm], steps)
        new_oracle = Base.invokelatest(F.identities, warm[:fixture].model)
        oracle = Base.invokelatest(_observe, warm, arm)
    end
    old_oracle !== nothing && new_oracle !== nothing ||
        error("Framework verification requires before/after oracle identities")
    expected_digest === nothing || oracle.digest == expected_digest || error("Framework oracle differs")
    H._stage(progress_path, :xp, arm, "before_framework_attribution_prepare")
    state = Base.invokelatest(_state, arm, config; performance=true)
    initial_identities = Base.invokelatest(F.identities, state[:fixture].model)
    simulation = state[:simulation]
    initial = Base.invokelatest(PSE.runtime_performance, simulation)
    before = initial
    step_reports = Any[]
    for step in 1:steps
        measured = H._timed(PSE.step!, simulation)
        after = Base.invokelatest(PSE.runtime_performance, simulation)
        push!(step_reports, (step, measurement=H._phase(measured),
            performance=_counter_delta(before,after)))
        before = after
    end
    observed = Base.invokelatest(_observe, state, arm; instrumented=true)
    expected_digest === nothing || observed.digest == expected_digest || error("Framework companion changed science/RNG/work")
    check = Base.invokelatest(_verify,
        (states=Any[state], identities=Any[initial_identities]), arm, oracle, old_oracle, new_oracle;
        instrumented=true)
    H._stage(progress_path, :xp, arm, "after_framework_attribution")
    return (arm, config, preparation=state[:phases], initial_performance=initial,
        steps=step_reports, final_performance=before, check,
        observed=(digest=observed.digest, work=observed.work, coverage=observed.coverage),
        interpretation=:instrumented_nested_framework_and_kernel_times_not_disjoint_product_timings,
        per_phase_allocations=:not_measured, binding_subphase_timers=:not_available_use_CPU_stacks,
        first_instrumented_call_may_compile=true)
end

Base.@nospecializeinfer @noinline function _sample_cpu!(states, steps)
    @nospecialize states
    Profile.@profile Base.invokelatest(_execute!, states, steps)
    return nothing
end
Base.@nospecializeinfer @noinline function _sample_allocations!(states, steps, rate)
    @nospecialize states
    Profile.Allocs.@profile sample_rate=rate Base.invokelatest(_execute!, states, steps)
    return nothing
end

Base.@nospecializeinfer @noinline function _unprepared_state(config)
    @nospecialize config
    constructed = H._timed(NBM._construct_binding_fixture, :xp, config)
    return Dict{Symbol,Any}(:fixture=>constructed.value, :simulation=>nothing,
        :constructor=>H._phase(constructed))
end

Base.@nospecializeinfer @noinline function _prepare_only!(states, arm, outputs)
    @nospecialize states outputs
    for state in states
        state[:simulation] = Base.invokelatest(SM.prepare_sequence_arm,
            state[:fixture].model, arm; outputs, performance=false,
            count_calls=false, details=false)
    end
    return nothing
end

Base.@nospecializeinfer @noinline function _sample_preparation_cpu!(states, arm, outputs)
    @nospecialize states outputs
    Profile.@profile Base.invokelatest(_prepare_only!, states, arm, outputs)
    return nothing
end

"""Sample repeated zero-step preparation without executing scientific kernels.

Eight independently constructed XP scenes are the maximum, with construction,
snapshots, model RNG fingerprints and reference checks outside CPU sampling.
One independent preparation warms the same helper before sampling. This is
warm-method fresh-model preparation attribution, not cold compilation timing.
"""
Base.@nospecializeinfer @noinline function profile_xp_preparation(arm::Symbol=:bounded_sequence;
    steps::Int=4, repetitions::Int=8, seed::Int=1, emission_speed=0.2,
    outputs=:none, cpu_delay=0.0002, max_cpu_words::Int=2^20,
    expected_digest=nothing, progress_path=nothing)
    1 <= steps <= 12 && 1 <= repetitions <= 8 || error("Preparation budget: 1-12 weather rows, 1-8 repetitions")
    cpu_delay >= 0.0001 && 1024 <= max_cpu_words <= 2^22 || error("Invalid CPU sampling budget")
    classifier_checks()
    roots = Base.invokelatest(_scientific_roots)
    config = H.construct_config(:xp; steps, seed, emission_speed, outputs)
    source_before = Base.invokelatest(M.source_manifest, pkgdir(PSE))
    H._stage(progress_path, :xp, arm, "before_preparation_profile_warmup")
    warm = Base.invokelatest(_unprepared_state, config)
    old_oracle = Base.invokelatest(F.identities, warm[:fixture].model)
    Base.invokelatest(_prepare_only!, Any[warm], arm, outputs)
    new_oracle = Base.invokelatest(F.identities, warm[:fixture].model)
    oracle = Base.invokelatest(_observe, warm, arm; require_newborn=false)
    warm[:simulation].current_step == 0 || error("Preparation warmup advanced science")
    expected_digest === nothing || oracle.digest == expected_digest || error("Zero-step oracle differs")
    states = Any[]; identities = Any[]
    for _ in 1:repetitions
        state = Base.invokelatest(_unprepared_state, config)
        push!(states, state)
        push!(identities, Base.invokelatest(F.identities, state[:fixture].model))
    end
    Profile.init(n=max_cpu_words, delay=cpu_delay); Profile.clear()
    H._stage(progress_path, :xp, arm, "before_preparation_CPU")
    measured = H._timed(_sample_preparation_cpu!, states, arm, outputs)
    H._stage(progress_path, :xp, arm, "after_preparation_CPU")
    full = Profile.is_buffer_full()
    data = Profile.fetch(; limitwarn=false)
    cpu = merge(Base.invokelatest(_cpu_summary, data, roots; entry_name="_prepare_only!"),
        (buffer_full=full, raw_words=length(data), raw_word_capacity=max_cpu_words, delay=cpu_delay))
    Profile.clear()
    cases = Any[]
    for (state, before) in zip(states, identities)
        simulation = state[:simulation]
        simulation.current_step == 0 || error("Sampled preparation advanced science")
        observed = Base.invokelatest(_observe, state, arm; require_newborn=false)
        isequal(observed.snapshot, oracle.snapshot) || error("Preparation changed zero-step science/history/topology/RNG")
        isequal(observed.work, oracle.work) || error("Preparation changed zero-step work")
        after = Base.invokelatest(F.identities, state[:fixture].model)
        F.same_identity_transitions(old_oracle, before, new_oracle, after) ||
            error("Preparation changed canonical reference transitions")
        push!(cases, (digest=observed.digest, work=observed.work,
            coverage=observed.coverage, constructor=state[:constructor], current_step=simulation.current_step))
    end
    source_after = Base.invokelatest(M.source_manifest, pkgdir(PSE))
    isequal(source_before, source_after) || error("Source image changed during preparation diagnostic")
    H._stage(progress_path, :xp, arm, "after_preparation_profile_diagnostics")
    return (passed=true, arm, config, repetitions, pid=getpid(), julia=string(VERSION),
        project=Base.active_project(), pse=Base.pathof(PSE), scientific_roots=roots,
        source_manifest=source_after, oracle=(digest=oracle.digest, work=oracle.work, coverage=oracle.coverage),
        cpu, cpu_measurement=H._phase(measured), cases,
        canonical_identity_transitions_match=true,
        sampled_region=:normal_zero_step_preparation_of_already_constructed_independent_models,
        scientific_kernel_steps=0, preparation_scope=:warm_methods_fresh_model_state,
        benchmark_claim=false, core_methods_changed=false,
        interpretation=:CPU_attribution_with_profiler_overhead_not_cold_compilation_or_product_timing)
end

"""Small XP diagnostic, with CPU and allocation runs on independent fresh scenes.

Load the existing DP, newborn instruction and sequence measurement modules
first. Definitions perform no science. Start with steps=4/repetitions=3, compare
:bounded_preparation against :bounded_sequence; expand to 12 days only if useful.
The function accepts at most 12 steps and five repetitions per call. It does
not replace uninstrumented balanced end-to-end comparisons. CPU/allocation
profiler overhead, JIT and GC remain in their diagnostic measurements.
"""
Base.@nospecializeinfer @noinline function profile_xp_growth_attribution(arm::Symbol=:bounded_sequence;
    steps::Int=4, repetitions::Int=3, seed::Int=1, emission_speed=0.2, outputs=:none,
    run_cpu::Bool=true, run_allocations::Bool=true, include_framework::Bool=true,
    allocation_sample_rate=0.01, cpu_delay=0.0005, max_cpu_words::Int=2^20,
    max_allocation_records::Int=50_000, progress_path=nothing, expected_digest=nothing)
    1 <= steps <= 12 && 1 <= repetitions <= 5 || error("Diagnostic budget: 1-12 steps, 1-5 repetitions")
    0 < allocation_sample_rate <= 0.05 || error("Allocation sample rate must be in (0,.05]")
    cpu_delay >= 0.0001 && 1024 <= max_cpu_words <= 2^22 || error("Invalid CPU sampling budget")
    classifier_checks()
    roots = Base.invokelatest(_scientific_roots)
    config = H.construct_config(:xp; steps, seed, emission_speed, outputs)
    source_before = Base.invokelatest(M.source_manifest, pkgdir(PSE))
    H._stage(progress_path, :xp, arm, "before_attribution_oracle")
    warm = Base.invokelatest(_state, arm, config)
    old_oracle = Base.invokelatest(F.identities, warm[:fixture].model)
    Base.invokelatest(_execute!, Any[warm], steps)
    new_oracle = Base.invokelatest(F.identities, warm[:fixture].model)
    oracle = Base.invokelatest(_observe, warm, arm)
    expected_digest === nothing || oracle.digest == expected_digest || error("Oracle differs from expected digest")
    cpu = cpu_measurement = cpu_check = nothing
    if run_cpu
        bundle = Base.invokelatest(_states, arm, config, repetitions)
        Profile.init(n=max_cpu_words, delay=cpu_delay); Profile.clear()
        H._stage(progress_path, :xp, arm, "before_attribution_CPU")
        measured = H._timed(_sample_cpu!, bundle.states, steps)
        H._stage(progress_path, :xp, arm, "after_attribution_CPU")
        full = Profile.is_buffer_full()
        data = Profile.fetch(; limitwarn=false)
        cpu = merge(Base.invokelatest(_cpu_summary, data, roots),
            (buffer_full=full, raw_words=length(data), raw_word_capacity=max_cpu_words, delay=cpu_delay))
        cpu_measurement = H._phase(measured)
        cpu_check = Base.invokelatest(_verify, bundle, arm, oracle, old_oracle, new_oracle)
        Profile.clear()
    end
    allocations = allocation_measurement = allocation_check = nothing
    if run_allocations
        bundle = Base.invokelatest(_states, arm, config, repetitions)
        Profile.Allocs.clear()
        H._stage(progress_path, :xp, arm, "before_attribution_allocations")
        measured = H._timed(_sample_allocations!, bundle.states, steps, allocation_sample_rate)
        H._stage(progress_path, :xp, arm, "after_attribution_allocations")
        allocations = Base.invokelatest(_allocation_summary, Profile.Allocs.fetch(), roots,
            allocation_sample_rate, max_allocation_records)
        allocation_measurement = H._phase(measured)
        allocation_check = Base.invokelatest(_verify, bundle, arm, oracle, old_oracle, new_oracle)
        Profile.Allocs.clear()
    end
    framework = include_framework ? Base.invokelatest(xp_framework_attribution, arm;
        steps, seed, emission_speed, outputs, expected_digest=oracle.digest, progress_path,
        oracle, old_oracle, new_oracle) : nothing
    source_after = Base.invokelatest(M.source_manifest, pkgdir(PSE))
    if !isequal(source_before, source_after)
        diagnostic_path = joinpath(pwd(), "benchmark/native_downstream/results/xp-growth-attribution/source-guard-inner-diagnostic.json")
        open(diagnostic_path, "w") do io
            PSE.JSON.print(io, (;source_before, source_after), 2)
        end
        error("Source image changed during diagnostic; details: $diagnostic_path")
    end
    H._stage(progress_path, :xp, arm, "after_attribution_diagnostics")
    return (passed=true, arm, config, repetitions, pid=getpid(), julia=string(VERSION),
        project=Base.active_project(), pse=Base.pathof(PSE), scientific_roots=roots,
        source_manifest=source_after, oracle=(digest=oracle.digest, work=oracle.work, coverage=oracle.coverage),
        cpu, cpu_measurement, cpu_check, allocations, allocation_measurement, allocation_check,
        framework, benchmark_claim=false, core_methods_changed=false,
        CPU_and_allocation_span=:growth_execution_after_zero_step_preparation,
        preparation_attribution=:diagnostic_constructor_and_prepare_measurements_plus_initial_framework_timers_not_CPU_sampled,
        budget=(max_steps=12, max_repetitions=5, max_cpu_words, max_allocation_records,
            allocation_limit=:post_collection_summary_guard_sampling_rate_controls_collection),
        interpretation=:separate_profile_companions_with_exact_scientific_work_and_state_parity)
end

end # module
