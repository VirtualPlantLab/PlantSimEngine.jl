# Additive lifecycle-preparation experiments. The :rebuild baseline remains in
# region_backend.jl. PSE still resolves every lifecycle/environment delta and
# decides which application groups are valid; this file avoids regenerating a
# second complete rich execution plan merely to lower it back to columns.

mutable struct RegionRefreshLog
    preparations::Int
    reused_column_batches::Int
    new_column_batches::Int
    temporary_root_contexts::Int
    full_plan_regenerations_avoided::Int
    midstep_refreshes::Int
    lowering_nanoseconds::UInt64
    runtime_refresh_nanoseconds::UInt64
end
RegionRefreshLog() = RegionRefreshLog(0, 0, 0, 0, 0, 0, UInt64(0), UInt64(0))

function region_refresh_report(log::RegionRefreshLog)
    return (preparations=log.preparations,
        reused_column_batches=log.reused_column_batches,
        new_column_batches=log.new_column_batches,
        temporary_root_contexts=log.temporary_root_contexts,
        full_plan_regenerations_avoided=log.full_plan_regenerations_avoided,
        midstep_refreshes=log.midstep_refreshes,
        lowering_seconds=Float64(log.lowering_nanoseconds) / 1.0e9,
        runtime_refresh_seconds=Float64(log.runtime_refresh_nanoseconds) / 1.0e9,
        meaning=:optional_diagnostic_timings_not_performance_samples)
end

function _reuse_region_column_batch(simulation, batch::RegionColumnBatch)
    factory = batch.targets.factory
    if batch.state isa RegionReferenceState && batch.state.appendable &&
       factory.compiled === simulation.compiled &&
       factory.environment_bindings === simulation.environment_bindings &&
       factory.application === batch.application &&
       factory.temporal_streams === simulation.temporal_streams &&
       factory.output_retention === simulation.output_retention &&
       factory.constants === simulation.constants
        return batch
    end
    # Reuse is legal only for a batch PSE itself left in its current plan.
    # Affected compact groups still take PSE's conservative general rebuild.
    # Replace the factory and one unused-but-dispatch-preserving root context
    # so an unchanged numerical batch cannot retain an obsolete compiled graph.
    factory = RegionTargetFactory(simulation.compiled, simulation.environment_bindings,
        batch.application, simulation.temporal_streams, simulation.output_retention,
        simulation.constants)
    object_ids = batch.targets.object_ids
    current = PSE._compiled_model_execution_target(simulation.compiled,
        simulation.environment_bindings, batch.application, first(object_ids),
        simulation.temporal_streams, simulation.output_retention, simulation.constants)
    old_kernel = batch.kernel
    kernel = GP.ColumnKernel{batch.output_publication.enabled,
        typeof(old_kernel.models),typeof(current.context),
        typeof(batch.environment_provider),typeof(old_kernel.output_bindings)}(
        old_kernel.models, current.context, batch.environment_provider,
        old_kernel.output_bindings)
    targets = RegionTargetView{typeof(current),typeof(object_ids),typeof(factory)}(
        object_ids, factory)
    return RegionColumnBatch(batch.application, targets, batch.environment_provider,
        batch.output_publication, kernel, batch.state, batch.counters)
end

_region_refresh_batch_key(batch::RegionColumnBatch) = batch.targets.object_ids
_region_refresh_batch_key(batch) = batch.targets

function _install_reused_region_batches!(simulation, replacements)
    isempty(replacements) && return nothing
    previous = simulation.execution_plan
    groups = PSE.CompiledApplicationExecutionGroup[]
    flat = PSE.AbstractExecutionBatch[]
    for group in previous.groups
        updated = PSE.AbstractExecutionBatch[]
        changed = false
        for batch in group.batches
            replacement = get(replacements, _region_refresh_batch_key(batch), batch)
            push!(updated, replacement)
            changed |= replacement !== batch
        end
        owner = changed ? PSE.CompiledApplicationExecutionGroup(group.application,
            RegionBatchCollection(updated)) : group
        push!(groups, owner)
        append!(flat, owner.batches)
    end
    simulation.execution_plan = _region_execution_plan_record(previous, groups, flat,
        PSE._execution_groups_by_application_slot(groups,
            length(simulation.compiled.scenario_plan.applications)),
        previous.schedule, previous.model_revision, previous.environment_revision)
    return nothing
end

function _compile_reused_regions_plan(simulation, config, counters)
    log = config.refresh_log
    started_at = isnothing(log) ? UInt64(0) : time_ns()
    # Explicitly disabling regions/compaction after a previous compilation must
    # still honor those controls. Fresh orthogonal benchmark arms never enter
    # this restoration path.
    if !config.regions || !config.compact || any(batch -> batch isa RegionColumnBatch &&
        (_region_state_strategy(batch.state) !== config.state_strategy ||
         (batch.state isa RegionReferenceState && batch.state.appendable !=
            (config.refresh_strategy === :append))),
        simulation.execution_plan.batches)
        _region_plain_execution_plan!(simulation)
    end
    schedule = simulation.compiled.scenario_plan.application_schedule
    nodes = Any[]
    replacements = IdDict{Any,Any}()
    reasons = NamedTuple[]
    states = NamedTuple[]
    selected_applications = Symbol[]
    selected_batches = selected_rows = total_rows = selected_contexts = 0
    reused_batches = new_batches = 0
    avoided_regeneration = any(batch -> batch isa RegionColumnBatch,
        simulation.execution_plan.batches)
    resolved_payloads = Any[]
    for (index, entry) in enumerate(schedule.entries)
        group = simulation.execution_plan.groups_by_application_slot[entry.application_slot]
        if isnothing(group)
            push!(nodes, RegionApplication(index, entry.application_slot, ()))
            continue
        end
        compiled_batches = Any[]
        for batch in group.batches
            total_rows += length(batch.targets)
            selected = nothing
            reason = config.regions ? :unknown_effects : :regions_disabled
            if config.regions && batch isa RegionColumnBatch
                selected = _reuse_region_column_batch(simulation, batch)
                reason = :reused_certified_unchanged_region
                reused_batches += 1
            elseif config.regions
                names, writes, reason = _region_batch_reason(simulation, batch)
                if reason === :eligible
                    try
                        selected = _make_region_column_batch(simulation, batch,
                            names, writes, counters; state_strategy=config.state_strategy,
                            appendable=config.refresh_strategy === :append)
                        new_batches += 1
                    catch error_
                        error_ isa ArgumentError || rethrow()
                        reason = :unsupported_scalar_schema_or_aliases
                    end
                end
            end
            if !isnothing(selected)
                push!(compiled_batches, selected)
                replacements[_region_refresh_batch_key(batch)] = selected
                selected_batches += 1
                selected_rows += length(batch.targets)
                selected_contexts += !isnothing(selected.kernel.context)
                push!(selected_applications, batch.application.id)
                push!(states, merge((application=batch.application.id,),
                    region_state_report(selected.state)))
            else
                resolved = config.resolved_calls && config.refresh_strategy !== :append &&
                    isnothing(simulation.performance) ?
                    _prepare_region_resolved_root(simulation, batch, config.call_strategy) : nothing
                if isnothing(resolved)
                    push!(compiled_batches, RegionOrderedBatch(batch))
                else
                    push!(compiled_batches, RegionResolvedBatch(resolved))
                    push!(resolved_payloads, resolved)
                end
            end
            push!(reasons, (application=batch.application.id,
                rows=length(batch.targets), reason))
        end
        push!(nodes, RegionApplication(index, entry.application_slot, Tuple(compiled_batches)))
    end
    config.compact && _install_reused_region_batches!(simulation, replacements)
    removed = config.compact ? selected_rows : 0
    retained_rich_rows = total_rows - removed
    report = (
        regions_requested=config.regions, resolved_calls_requested=config.resolved_calls,
        call_strategy_requested=config.call_strategy,
        refresh_strategy_requested=config.refresh_strategy,
        state_strategy_requested=config.state_strategy,
        compact_requested=config.compact, region_applications=length(unique(selected_applications)),
        selected_applications=Tuple(unique(selected_applications)), column_batches=selected_batches,
        column_target_memberships=selected_rows, total_target_memberships=total_rows,
        execution_records_removed=removed, retained_rich_root_records=retained_rich_rows,
        retained_local_root_contexts=selected_contexts,
        retained_root_contexts=retained_rich_rows + selected_contexts,
        retained_compiled_status_views=length(simulation.compiled.status_views_by_target),
        canonical_references_replaced=false,
        canonical_scalar_copy_retained=any(state -> state.duplicate_scalar_columns, states),
        native_column_fields=sum(state.native_column_fields for state in states; init=0),
        state_layout=config.state_strategy === :references ?
            :borrowed_live_reference_columns : :borrowed_ports_with_application_boundary_sync,
        selected_state=Tuple(states), reasons=Tuple(reasons),
        reused_column_batches=reused_batches, new_column_batches=new_batches,
        redundant_plain_regeneration_avoided=avoided_regeneration,
        resolved_payloads=Tuple(resolved_payloads),
    )
    if !isnothing(log)
        log.preparations += 1
        log.reused_column_batches += reused_batches
        log.new_column_batches += new_batches
        log.temporary_root_contexts += reused_batches
        log.full_plan_regenerations_avoided += avoided_regeneration
        log.lowering_nanoseconds += time_ns() - started_at
    end
    return RegionPlan(Tuple(nodes), schedule, simulation.runtime_revision,
        simulation.environment_bindings.environment_revision, report)
end

Base.@noinline function _run_eager_region_application!(node::RegionApplication,
    simulation, step, counters)
    _run_region_batches!(node.batches, simulation, step, counters)
    return nothing
end

function _eager_region_node(plan, index, application_slot)
    if index <= length(plan.nodes)
        node = plan.nodes[index]
        node.application_slot == application_slot && return node
    end
    # Preserve the original scheduler's old-slot iteration if a lifecycle edit
    # also changed application ordering. This cold case never assumes that a
    # previous index still identifies the same current application.
    for node in plan.nodes
        node.application_slot == application_slot && return node
    end
    return nothing
end

function _step_eager_regions!(program, plan, step)
    simulation = program.simulation
    simulation.compiled.execution_generation += UInt64(1)
    empty!(simulation.environment_bindings.sample_cache)
    schedule = plan.schedule
    due = PSE._due_application_schedule_entries!(simulation.execution_plan.schedule,
        schedule, Int(step))
    completed = nothing
    for entry_index in due
        entry = schedule.entries[entry_index]
        node = _eager_region_node(program.plan, entry_index, entry.application_slot)
        isnothing(node) || _run_eager_region_application!(node, simulation,
            step, program.counters)
        PSE._simulation_runtime_dirty(simulation, simulation.performance) || continue
        log = program.config.refresh_log
        started_at = isnothing(log) ? UInt64(0) : time_ns()
        completed = GP._program_refresh_after!(simulation, schedule, completed, entry_index)
        if !isnothing(log)
            log.midstep_refreshes += 1
            log.runtime_refresh_nanoseconds += time_ns() - started_at
        end
        # Refresh all structural/environment semantics through PSE first, then
        # lower exactly its current certified groups before the next app runs.
        program.plan = _compile_reused_regions_plan(simulation, program.config,
            program.counters)
        program.rebuilds += 1
    end
    simulation.current_step = step
    return nothing
end

"""Small parity gates for preparation reuse and same-step region recovery."""
function refresh_region_checks(; downstream_builder=nothing, downstream_steps=4)
    reports = NamedTuple[]
    fixtures = [
        (name=:same_step_growth, builder=GP.growth_fixture, steps=3),
        (name=:cross_object_reduce, builder=GP.reduction_fixture, steps=3),
        (name=:multirate_previous_step, builder=GP.temporal_fixture, steps=4),
        (name=:manual_calls, builder=GP.call_fixture, steps=3),
        (name=:spatial_environment, builder=() -> GP.completion_spatial_fixture().model, steps=2),
        (name=:optional_targets, builder=GP.completion_optional_fixture, steps=2),
        (name=:initializer, builder=GP.completion_initializer_fixture, steps=2),
        (name=:distributed_assignment, builder=GP.completion_assignment_fixture, steps=2),
    ]
    isnothing(downstream_builder) || push!(fixtures,
        (name=:downstream_growth, builder=downstream_builder, steps=downstream_steps))
    @testset "Reuse and eager region refresh preserve PSE semantics" begin
        for fixture in fixtures, strategy in (:reuse, :eager), compact in (false, true)
            reference = PSE.run!(fixture.builder(); steps=0, outputs=:all)
            simulation = PSE.run!(fixture.builder(); steps=0, outputs=:all)
            log = RegionRefreshLog()
            program = compile_regions(simulation; resolved_calls=false,
                refresh_strategy=strategy, refresh_log=log, compact)
            for _ in 1:fixture.steps
                PSE.continue!(reference; steps=1)
                advance_regions!(program; steps=1)
                @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
            end
            # Normal continuation remains legal after either preparation mode.
            PSE.continue!(reference; steps=1)
            PSE.continue!(simulation; steps=1)
            @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
            report = region_report(program)
            @test report.refresh_strategy_requested === strategy
            push!(reports, (fixture=fixture.name, strategy, compact,
                column_rows=report.column_row_executions,
                rebuilds=report.rebuilds, refresh=region_refresh_report(log)))
        end

        # Movement and reparenting invalidate spatial handles and selection;
        # mutable backend state must be sampled freshly even without a new
        # backend identity or schema. Both refresh modes keep this ordered path.
        for strategy in (:reuse, :eager), compact in (false, true)
            control = GP.completion_spatial_fixture()
            fixture = GP.completion_spatial_fixture()
            reference = PSE.run!(control.model; steps=0, outputs=:all)
            simulation = PSE.run!(fixture.model; steps=0, outputs=:all)
            program = compile_regions(simulation; resolved_calls=false,
                refresh_strategy=strategy, compact)
            empty!(control.backend.samples)
            empty!(fixture.backend.samples)
            for step in 1:4
                if step == 2
                    PSE.move_object!(control.model, :a, (cell=:shade,))
                    PSE.move_object!(fixture.model, :a, (cell=:shade,))
                elseif step == 3
                    PSE.reparent_object!(control.model, :unit, :b)
                    PSE.reparent_object!(fixture.model, :unit, :b)
                elseif step == 4
                    control.backend.values[:sun] = 31.0
                    fixture.backend.values[:sun] = 31.0
                end
                PSE.continue!(reference; steps=1)
                advance_regions!(program; steps=1)
                @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
                @test fixture.backend.samples == control.backend.samples
                @test PSE.final_state(simulation, :unit).seen == (10.0, 20.0, 10.0, 31.0)[step]
            end
            push!(reports, (fixture=:spatial_move_reparent_mutation, strategy, compact,
                column_rows=program.counters.column_rows, rebuilds=program.rebuilds,
                refresh=nothing))
        end
    end
    return (; cases=length(reports), reports)
end
