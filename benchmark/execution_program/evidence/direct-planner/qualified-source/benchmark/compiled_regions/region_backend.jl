# Mixed column regions. This file is included in CompiledRegionsExperiment.
# The numerical kernel is unchanged. Applications keep their ordinary order;
# each selected batch copies live scalar ports in, executes over columns, and
# publishes/writes back before the next batch or structural boundary.

"""
    region_effects(::Type) = GP.program_effects(Type)

`:local_ports` is an explicit author audit: a total kernel reads only its
declared scalar status inputs/outputs and writes only declared outputs. It uses
ordinary Status property access, with no representation-dependent dispatch,
reflection, context observation, escaped references, RNG, mutable shared caches,
or indirect status aliases through parameters, forcing or constants. Input/output
overlap may mutate that shared cell. `:local` keeps the prior full-status promise.
Unregistered models retain ordinary execution.
"""
region_effects(T::Type) = GP.program_effects(T)

mutable struct RegionExecutionCounters
    column_batches::Int
    column_rows::Int
    ordered_batches::Int
    resolved_batches::Int
    appended_batches::Int
    appended_rows::Int
end
RegionExecutionCounters() = RegionExecutionCounters(0, 0, 0, 0, 0, 0)

mutable struct RegionTargetFactory{CS,EB,A,TS,OR,C}
    compiled::CS
    environment_bindings::EB
    application::A
    temporal_streams::TS
    output_retention::OR
    constants::C
end

"""Logical target inspection reconstructs a snapshot; no rich target is cached."""
struct RegionTargetView{T,I,F} <: AbstractVector{T}
    object_ids::I
    factory::F
end
Base.size(targets::RegionTargetView) = size(targets.object_ids)
Base.length(targets::RegionTargetView) = length(targets.object_ids)
Base.IndexStyle(::Type{<:RegionTargetView}) = IndexLinear()
# Unchanged-source benchmarks lack this new cold-refresh capability. Keep
# their loader working without changing their original executor; compact
# removal correctness is qualified separately with the core hook present.
if isdefined(PSE, :_model_execution_target_id)
    @inline PSE._model_execution_target_id(targets::RegionTargetView, index) =
        targets.object_ids[index]
end
function Base.getindex(targets::RegionTargetView, index::Int)
    object_id = targets.object_ids[index]
    factory = targets.factory
    # The element type describes the logical snapshot at installation. A
    # lifecycle refresh may change its schema; affected compact groups always
    # take the general rebuild path below before they execute again.
    return PSE._compiled_model_execution_target(factory.compiled,
        factory.environment_bindings, factory.application, object_id,
        factory.temporal_streams, factory.output_retention, factory.constants)
end

mutable struct RegionColumnBatch{A,T,E,O,K,S,C} <: PSE.AbstractExecutionBatch
    application::A
    targets::T
    environment_provider::E
    output_publication::O
    kernel::K
    state::S
    counters::C
end

struct RegionOrderedBatch{B}
    batch::B
end
struct RegionResolvedBatch{B}
    payload::B
end
struct RegionApplication{B}
    entry::Int
    application_slot::Int
    batches::B
end

# Distinct group storage makes ordinary PSE lifecycle refresh conservative for
# compact roots. It does not retain the original group, batch or target vector.
struct RegionBatchCollection <: AbstractVector{PSE.AbstractExecutionBatch}
    batches::Vector{PSE.AbstractExecutionBatch}
end
Base.size(batches::RegionBatchCollection) = size(batches.batches)
Base.length(batches::RegionBatchCollection) = length(batches.batches)
Base.getindex(batches::RegionBatchCollection, index::Int) = batches.batches[index]
Base.IndexStyle(::Type{RegionBatchCollection}) = IndexLinear()

mutable struct RegionPlan{N,S,R}
    nodes::N
    schedule::S
    runtime_revision::Int
    environment_revision::Int
    report::R
end

mutable struct CompiledRegionProgram{S,C}
    simulation::S
    plan::Any
    config::C
    counters::RegionExecutionCounters
    rebuilds::Int
end

program_simulation(program::CompiledRegionProgram) = program.simulation

function _region_port_schema(target)
    effect = region_effects(typeof(target.model))
    effect in (:local, :local_ports) || return (nothing, nothing, :unknown_effects)
    names = if effect === :local
        Tuple(keys(target.status))
    else
        Tuple(unique((keys(PSE.inputs_(target.model))...,
            keys(PSE.outputs_(target.model))...)))
    end
    writes = effect === :local ? names : Tuple(keys(PSE.outputs_(target.model)))
    all(name -> name in keys(target.status), names) ||
        return (nothing, nothing, :missing_status_port)
    return (names, writes, :eligible)
end

function _region_batch_reason(simulation, batch)
    isnothing(simulation.performance) || return (nothing, nothing, :performance_instrumentation)
    batch isa PSE.CompiledExecutionBatch || return (nothing, nothing, :unsupported_batch)
    isempty(batch.targets) && return (nothing, nothing, :empty_batch)
    # Global row sampling remains exactly once at the original batch boundary,
    # before pulling status. No forcing sampling is moved ahead of another app.
    batch.environment_provider isa PSE.UnspecifiedModelEnvironment &&
        return (nothing, nothing, :per_object_environment_boundary)
    first_names = nothing
    first_writes = nothing
    for target in batch.targets
        names, writes, reason = _region_port_schema(target)
        reason === :eligible || return (nothing, nothing, reason)
        if isnothing(first_names)
            first_names, first_writes = names, writes
        elseif names != first_names || writes != first_writes
            return (nothing, nothing, :heterogeneous_port_schema)
        end
        isempty(target.call_bindings) || return (nothing, nothing, :manual_or_initializer_calls)
        isempty(target.input_bindings) || return (nothing, nothing, :temporal_input_boundary)
        isempty(target.output_targets) || return (nothing, nothing, :distributed_output_boundary)
        isempty(PSE.environment_outputs_(target.model)) ||
            return (nothing, nothing, :environment_commit_boundary)
        all(output -> output isa PSE.RuntimeOutputStream, target.output_bindings) ||
            return (nothing, nothing, :distributed_publication_boundary)
    end
    return (first_names, first_writes, :eligible)
end

function _region_kernel(batch)
    targets = batch.targets
    first_target = first(targets)
    model = first_target.model
    models = all(target -> target.model === model, targets) ?
        GP.SharedColumnModel(model) :
        GP.PerRowColumnModels(GP._program_concrete_vector([target.model for target in targets]))
    context = first_target.context
    all(target -> typeof(target.context) === typeof(context), targets) ||
        throw(ArgumentError("Region kernels require one context dispatch type."))
    bindings = GP._program_concrete_vector([target.output_bindings for target in targets])
    return GP.ColumnKernel{batch.output_publication.enabled,
        typeof(models),typeof(context),typeof(batch.environment_provider),typeof(bindings)}(
        models, context, batch.environment_provider, bindings)
end

function _make_region_column_batch(simulation, batch, names, writes, counters;
    state_strategy::Symbol=:columns, appendable::Bool=false)
    state = state_strategy === :references ?
        prepare_region_reference_state(batch.targets, names, writes; appendable) :
        prepare_region_state(batch.targets, names, writes)
    kernel = _region_kernel(batch)
    object_ids = GP._program_concrete_vector([target.object_id for target in batch.targets])
    factory = RegionTargetFactory(simulation.compiled, simulation.environment_bindings,
        batch.application, simulation.temporal_streams, simulation.output_retention,
        simulation.constants)
    logical_targets = RegionTargetView{eltype(batch.targets),typeof(object_ids),typeof(factory)}(
        object_ids, factory)
    return RegionColumnBatch(batch.application, logical_targets,
        batch.environment_provider, batch.output_publication, kernel, state, counters)
end

@inline function _run_region_column_batch!(batch::RegionColumnBatch, compiled,
    environment_bindings, step, constants, temporal_streams, output_retention)
    # Preserve the original global sampling site and relative order, including
    # its side effects. Only then gather live scalar inputs and prior state.
    environment = PSE._model_execution_batch_environment(batch.environment_provider,
        environment_bindings, batch.application, step)
    pull_region_state!(batch.state)
    context = batch.kernel.context
    context isa PSE.RunContext && (context.time = float(step))
    GP._column_numerical_loop!(batch.state.data, (batch.kernel,), (environment,),
        constants, step)
    push_region_state!(batch.state)
    batch.counters.column_batches += 1
    batch.counters.column_rows += batch.state.data.nrows
    return nothing
end

function PSE._run_model_execution_batch!(batch::RegionColumnBatch,
    compiled::PSE.CompiledCompositeModel,
    environment_bindings::PSE.CompiledEnvironmentBindings, step::Real,
    constants, temporal_streams, output_retention)
    return _run_region_column_batch!(batch, compiled, environment_bindings,
        step, constants, temporal_streams, output_retention)
end

function PSE._model_execution_batch_accepts_target(batch::RegionColumnBatch,
    target, environment_bindings, application)
    # Ordinary lifecycle code must rebuild a normal group, never try to append
    # or mutate the logical snapshot view as if it held rich target rows.
    return false
end

function PSE._model_execution_group_reusable(
    group::PSE.CompiledApplicationExecutionGroup{A,RegionBatchCollection},
    compiled::PSE.CompiledCompositeModel,
    environment_bindings::PSE.CompiledEnvironmentBindings,
    application::PSE.CompiledModelApplication,
    output_retention=nothing, temporal_streams=nothing,
) where {A}
    return false
end

function PSE._refresh_model_execution_group_delta!(
    group::PSE.CompiledApplicationExecutionGroup{A,RegionBatchCollection},
    compiled::PSE.CompiledCompositeModel,
    environment_bindings::PSE.CompiledEnvironmentBindings,
    application::PSE.CompiledModelApplication,
    temporal_streams, output_retention, constants, performance,
    changed_object_ids, shared_plan_cache=nothing,
) where {A}
    return nothing
end

@inline function _run_region_batch!(batch::RegionColumnBatch, simulation, step, counters)
    _run_region_column_batch!(batch, simulation.compiled, simulation.environment_bindings,
        step, simulation.constants, simulation.temporal_streams, simulation.output_retention)
    return nothing
end
@inline function _run_region_batch!(node::RegionOrderedBatch, simulation, step, counters)
    GP._program_run_original_batch!(node.batch, simulation, step)
    counters.ordered_batches += 1
    return nothing
end
@inline function _run_region_batch!(node::RegionResolvedBatch, simulation, step, counters)
    execute_resolved_root!(node.payload, simulation, step)
    counters.resolved_batches += 1
    return nothing
end

@generated function _run_region_batches!(batches::B, simulation, step, counters) where {B<:Tuple}
    return Expr(:block, [:( _run_region_batch!(getfield(batches, $i), simulation,
        step, counters)) for i in 1:fieldcount(B)]..., :(nothing))
end

function _region_plain_execution_plan!(simulation)
    any(batch -> batch isa RegionColumnBatch, simulation.execution_plan.batches) || return nothing
    previous_schedule = simulation.execution_plan.schedule
    rebuilt = PSE.compile_model_execution_plan(simulation.compiled,
        simulation.environment_bindings, simulation.temporal_streams,
        simulation.output_retention, simulation.constants)
    schedule = PSE._runtime_application_schedule(
        simulation.compiled.scenario_plan.application_schedule;
        after_step=simulation.current_step)
    append!(schedule.due_entry_indices, previous_schedule.due_entry_indices)
    simulation.execution_plan = _region_execution_plan_record(rebuilt, rebuilt.groups,
        rebuilt.batches, rebuilt.groups_by_application_slot, schedule,
        rebuilt.model_revision, rebuilt.environment_revision)
    return nothing
end

# Revision-comparison experiments load these helpers against the unchanged
# original executor too. Copy the common record fields and preserve every
# trailing metadata field from the loaded record, without adding a public API.
function _region_execution_plan_record(previous, groups, batches, slots,
    schedule, model_revision, environment_revision)
    trailing = ntuple(index -> getfield(previous, index + 6),
        fieldcount(typeof(previous)) - 6)
    return typeof(previous)(groups, batches, slots, schedule,
        model_revision, environment_revision, trailing...)
end

function _install_region_batches!(simulation, replacements)
    isempty(replacements) && return 0
    previous = simulation.execution_plan
    groups = PSE.CompiledApplicationExecutionGroup[]
    batches = PSE.AbstractExecutionBatch[]
    replaced = 0
    for group in previous.groups
        updated = PSE.AbstractExecutionBatch[]
        changed = false
        for batch in group.batches
            replacement = get(replacements, batch.targets, nothing)
            if isnothing(replacement)
                push!(updated, batch)
            else
                push!(updated, replacement)
                replaced += length(batch.targets)
                changed = true
            end
        end
        new_group = changed ? PSE.CompiledApplicationExecutionGroup(group.application,
            RegionBatchCollection(updated)) : group
        push!(groups, new_group)
        append!(batches, new_group.batches)
    end
    simulation.execution_plan = _region_execution_plan_record(previous, groups, batches,
        PSE._execution_groups_by_application_slot(groups,
            length(simulation.compiled.scenario_plan.applications)),
        previous.schedule, previous.model_revision, previous.environment_revision)
    return replaced
end

function _prepare_region_resolved_root(simulation, batch, strategy::Symbol)
    factory = strategy === :guarded ? :prepare_resolved_root :
        strategy === :epoch ? :prepare_epoch_resolved_root : :prepare_inline_resolved_root
    isdefined(@__MODULE__, factory) || throw(ArgumentError(
        "Call strategy $(strategy) requires its experimental helper to be included.",
    ))
    return getfield(@__MODULE__, factory)(simulation, batch)
end

function _compile_regions_plan(simulation, config, counters)
    config.refresh_strategy === :rebuild ||
        return _compile_reused_regions_plan(simulation, config, counters)
    _region_plain_execution_plan!(simulation)
    schedule = simulation.compiled.scenario_plan.application_schedule
    nodes = Any[]
    replacements = IdDict{Any,Any}()
    reasons = NamedTuple[]
    states = NamedTuple[]
    selected_applications = Symbol[]
    selected_batches = 0
    selected_rows = 0
    total_rows = 0
    selected_contexts = 0
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
            if config.regions
                names, writes, reason = _region_batch_reason(simulation, batch)
                if reason === :eligible
                    try
                        selected = _make_region_column_batch(simulation, batch,
                            names, writes, counters; state_strategy=config.state_strategy)
                    catch error_
                        error_ isa ArgumentError || rethrow()
                        reason = :unsupported_scalar_schema_or_aliases
                    end
                end
            end
            if !isnothing(selected)
                push!(compiled_batches, selected)
                replacements[batch.targets] = selected
                selected_batches += 1
                selected_rows += length(batch.targets)
                selected_contexts += !isnothing(selected.kernel.context)
                push!(selected_applications, batch.application.id)
                push!(states, merge((application=batch.application.id,),
                    region_state_report(selected.state)))
            else
                resolved = config.resolved_calls && isnothing(simulation.performance) ?
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
    removed = config.compact ? _install_region_batches!(simulation, replacements) : 0
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
        # One original typed context per numerical batch preserves dispatch.
        retained_local_root_contexts=selected_contexts,
        retained_root_contexts=retained_rich_rows + selected_contexts,
        retained_compiled_status_views=length(simulation.compiled.status_views_by_target),
        canonical_references_replaced=false,
        canonical_scalar_copy_retained=any(state -> state.duplicate_scalar_columns, states),
        native_column_fields=sum(state.native_column_fields for state in states; init=0),
        state_layout=config.state_strategy === :references ?
            :borrowed_live_reference_columns : :borrowed_ports_with_application_boundary_sync,
        selected_state=Tuple(states), reasons=Tuple(reasons),
        resolved_payloads=Tuple(resolved_payloads),
    )
    return RegionPlan(Tuple(nodes), schedule, simulation.runtime_revision,
        simulation.environment_bindings.environment_revision, report)
end

"""
    compile_regions(simulation; regions=true, resolved_calls=true, compact=true,
        call_strategy=:guarded, refresh_strategy=:rebuild, refresh_log=nothing,
        state_strategy=:columns)

Lower audited scalar batches in a mixed simulation. Unknown calls, temporal
inputs, distributed destinations, mutable ports and per-object environments
retain ordered execution. Selected application boundaries synchronize existing
live reference carriers. `compact` installs numerical batches in all root-plan
owners and removes their rich target/context/cache rows; ordinary continue!
uses the same installed numerical batches and lifecycle rebuilds remain legal.
"""
function compile_regions(simulation; regions::Bool=true,
    resolved_calls::Bool=true, compact::Bool=true, call_strategy::Symbol=:guarded,
    refresh_strategy::Symbol=:rebuild, refresh_log=nothing,
    state_strategy::Symbol=:columns)
    call_strategy in (:guarded, :epoch, :inline) || throw(ArgumentError(
        "call_strategy must be :guarded, :epoch or :inline.",
    ))
    refresh_strategy in (:rebuild, :reuse, :eager, :append) || throw(ArgumentError(
        "refresh_strategy must be :rebuild, :reuse, :eager or :append.",
    ))
    refresh_strategy === :rebuild || isdefined(@__MODULE__, :_compile_reused_regions_plan) ||
        throw(ArgumentError("Include refresh_regions.jl for lifecycle preparation experiments."))
    state_strategy in (:columns, :references) || throw(ArgumentError(
        "state_strategy must be :columns or :references.",
    ))
    state_strategy === :columns || isdefined(@__MODULE__, :prepare_region_reference_state) ||
        throw(ArgumentError("Include reference_regions.jl for borrowed reference regions."))
    refresh_strategy === :append && (!compact || state_strategy !== :references) &&
        throw(ArgumentError("Append refresh requires compact live-reference regions."))
    PSE._compiled_source_finalize!(simulation)
    config = (;regions, resolved_calls, compact, call_strategy, refresh_strategy,
        refresh_log, state_strategy)
    counters = RegionExecutionCounters()
    plan = _compile_regions_plan(simulation, config, counters)
    return CompiledRegionProgram(simulation, plan, config, counters, 0)
end

function _ensure_regions!(program)
    simulation = program.simulation
    PSE._compiled_source_finalize!(simulation)
    if program.plan.runtime_revision != simulation.runtime_revision ||
       program.plan.environment_revision != simulation.environment_bindings.environment_revision
        program.plan = _compile_regions_plan(simulation, program.config, program.counters)
        program.rebuilds += 1
    end
    return program.plan
end

function _region_entry_due(schedule, index, step)
    entry = schedule.entries[index]
    entry.kind === :always && return true
    if entry.kind === :periodic_integer
        period = something(entry.period_steps)
        return mod(step, period) == mod(something(entry.phase_step), period)
    end
    return PSE._generic_schedule_entry_is_due(entry, Int(step))
end

@generated function _run_region_nodes!(nodes::N, simulation, step, schedule, counters) where {N<:Tuple}
    operations = Expr[]
    for index in 1:fieldcount(N)
        push!(operations, quote
            node = getfield(nodes, $index)
            if _region_entry_due(schedule, node.entry, step)
                if changed
                    group = simulation.execution_plan.groups_by_application_slot[node.application_slot]
                    isnothing(group) || PSE._run_model_execution_group!(group,
                        simulation, step, simulation.performance)
                else
                    _run_region_batches!(node.batches, simulation, step, counters)
                end
                if PSE._simulation_runtime_dirty(simulation, simulation.performance)
                    completed = GP._program_refresh_after!(simulation, schedule,
                        completed, node.entry)
                    changed = true
                end
            end
        end)
    end
    return quote
        changed = false
        completed = nothing
        $(operations...)
        nothing
    end
end

function _step_regions!(program, plan, step)
    program.config.refresh_strategy === :eager &&
        return _step_eager_regions!(program, plan, step)
    simulation = program.simulation
    simulation.compiled.execution_generation += UInt64(1)
    empty!(simulation.environment_bindings.sample_cache)
    PSE._due_application_schedule_entries!(simulation.execution_plan.schedule,
        plan.schedule, Int(step))
    _run_region_nodes!(plan.nodes, simulation, step, plan.schedule, program.counters)
    simulation.current_step = step
    return nothing
end

function advance_regions!(program::CompiledRegionProgram; steps::Integer=1)
    steps >= 0 || throw(ArgumentError("steps must be non-negative"))
    if program.config.refresh_strategy === :append
        # Installed appendable batches remain owners across ordinary lifecycle
        # barriers. Calls and unsupported edits use the standard executor.
        PSE.continue!(program.simulation; steps)
        _ensure_regions!(program)
        return program.simulation
    end
    if !isnothing(program.simulation.performance)
        PSE.continue!(program.simulation; steps)
        return program.simulation
    end
    for _ in 1:steps
        plan = _ensure_regions!(program)
        _step_regions!(program, plan, program.simulation.current_step + 1)
    end
    _ensure_regions!(program)
    return program.simulation
end

function region_report(program::CompiledRegionProgram)
    report = program.plan.report
    call_reports = isdefined(@__MODULE__, :resolved_root_report) ?
        map(resolved_root_report, report.resolved_payloads) : ()
    total(name) = sum(getproperty(row, name) for row in call_reports; init=0)
    return merge(Base.structdiff(report, (resolved_payloads=nothing,)), (
        rebuilds=program.rebuilds, current_step=program.simulation.current_step,
        column_batch_executions=program.counters.column_batches,
        column_row_executions=program.counters.column_rows,
        ordered_batch_executions=program.counters.ordered_batches,
        resolved_batch_executions=program.counters.resolved_batches,
        append_batch_commits=program.counters.appended_batches,
        append_row_memberships=program.counters.appended_rows,
        append_scheduler=program.config.refresh_strategy === :append ? :ordinary : :region,
        call_fast_hits=total(:fast_calls), call_fast_targets=total(:fast_targets),
        call_model_lookups=total(:model_lookups), call_fallback_hits=total(:fallback_calls),
        call_selected_roots=total(:selected_roots), call_selected_edges=total(:selected_edges),
        resolved_calls=call_reports,
    ))
end
