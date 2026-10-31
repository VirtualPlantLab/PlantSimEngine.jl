module LeanNativeGrowth

using PlantSimEngine
const PSE = PlantSimEngine
if !isdefined(Main, :LeanNativeCompiler)
    Base.include(Main, joinpath(@__DIR__, "lean_compiler.jl"))
end
const Lean = Main.LeanNativeCompiler
const Driver = Main.LeanNativeDriver
const CR = Main.CompiledRegionsExperiment
const GP = CR.GP

export prepare_growth, growth_report, GrowingLeanBatch

mutable struct GrowthRecord
    initial_ids::Set{PSE.ObjectId}
    lean_record::Lean.LeanCompilationRecord
    plan_batches::Any
    captured_token::Tuple{Int,Int,Int}
    pending_addition::Bool
    added_ids::Set{PSE.ObjectId}
    state_strategy::Symbol
    disabled::Bool
    counters::Vector{Driver.LeanDriverCounters}
    known_counters::IdDict{Driver.LeanDriverCounters,Nothing}
    incremental_refreshes::Int
    reused_batches::Int
    reused_numeric_groups::Int
    appended_rows::Int
    coalesced_batches::Int
    rebuilt_numeric_batches::Int
    rebuilt_ordinary_groups::Int
    reused_ordinary_groups::Int
    rich_targets_constructed::Int
    native_newborn_row_executions::Int
    full_invalidations::Int
    reasons::Vector{NamedTuple}
end

function GrowthRecord(model, strategy)
    return GrowthRecord(Set(PSE.object_ids(model)), Lean.LeanCompilationRecord(),
        nothing, (-1, -1, -1), false, Set{PSE.ObjectId}(), strategy, false,
        Driver.LeanDriverCounters[], IdDict{Driver.LeanDriverCounters,Nothing}(),
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, NamedTuple[])
end

"""
An ordinary scheduler batch with one bounded typed numerical payload. Row IDs
are immutable for its lifetime. A single shared record captures an addition
before the semantic runtime consumes it and records actual newborn execution.
"""
struct GrowingLeanBatch{B} <: PSE.AbstractExecutionBatch
    inner::B
    state::GrowthRecord
    row_ids::Vector{PSE.ObjectId}
    newborn_rows::Int
end

function Base.getproperty(batch::GrowingLeanBatch, name::Symbol)
    name in (:inner, :state, :row_ids, :newborn_rows) && return getfield(batch, name)
    return getproperty(getfield(batch, :inner), name)
end
Base.propertynames(batch::GrowingLeanBatch, private::Bool=false) = private ?
    (propertynames(batch.inner)..., :inner, :state, :row_ids, :newborn_rows) :
    propertynames(batch.inner)

const _reports = WeakKeyDict{Any,GrowthRecord}()
_model_token(model) = (model.runtime_revision, model.revision, model.environment_revision)

function _register_counter!(state, counter)
    if !haskey(state.known_counters, counter)
        state.known_counters[counter] = nothing
        push!(state.counters, counter)
    end
    return nothing
end

function _wrap(batch::Driver.LeanNumericalBatch, state)
    ids = batch.targets isa Lean.LeanTargetView ? batch.targets.object_ids :
        PSE.ObjectId[id for id in batch.targets]
    _register_counter!(state, batch.counters)
    newborn = count(id -> !(id in state.initial_ids), ids)
    return GrowingLeanBatch(batch, state, ids, newborn)
end

PSE._execution_batch_requires_full_refresh(::GrowingLeanBatch) = true

function PSE._capture_execution_batch_refresh_state!(batch::GrowingLeanBatch, model)
    state = batch.state
    state.disabled && return nothing
    token = _model_token(model)
    token == state.captured_token && return nothing
    delta = PSE.lifecycle_delta(model)
    added = Set(snapshot.id for snapshot in delta.added)
    state.pending_addition = delta.structural_kind === :addition &&
        !isempty(added) && !delta.full_environment && isempty(delta.removed) &&
        isempty(delta.reparented) && isempty(delta.moved) &&
        all(id -> id in added, delta.environment_dirty_ids)
    state.added_ids = added
    state.captured_token = token
    return nothing
end

Base.@nospecializeinfer @noinline function PSE._run_model_execution_batch!(
    batch::GrowingLeanBatch{B}, compiled::PSE.CompiledCompositeModel,
    environment_bindings::PSE.CompiledEnvironmentBindings, time::Real,
    constants::C, temporal_streams, output_retention,
) where {B,C}
    @nospecialize compiled environment_bindings temporal_streams output_retention
    PSE._run_model_execution_batch!(batch.inner, compiled, environment_bindings,
        time, constants, temporal_streams, output_retention)
    batch.inner.native &&
        (batch.state.native_newborn_row_executions += batch.newborn_rows)
    return nothing
end

PSE._explain_execution_batch(batch::GrowingLeanBatch, index) =
    PSE._explain_execution_batch(batch.inner, index)
PSE._compiled_source_prepare_batch(simulation::PSE.Simulation,
    batch::GrowingLeanBatch, time::Real) =
    PSE._compiled_source_prepare_batch(simulation, batch.inner, time)

function _wrap_plan(plan, state)
    groups = PSE.CompiledApplicationExecutionGroup[]
    batches = PSE.AbstractExecutionBatch[]
    for group in plan.groups
        selected = PSE.AbstractExecutionBatch[
            batch isa Driver.LeanNumericalBatch ? _wrap(batch, state) : batch
            for batch in group.batches]
        bounded = all(batch -> batch isa GrowingLeanBatch, selected) ?
            Lean._bounded_application_batches(selected) : selected
        push!(groups, PSE.CompiledApplicationExecutionGroup(group.application, bounded))
        append!(batches, selected)
    end
    result = PSE.CompiledExecutionPlan(groups, batches,
        PSE._execution_groups_by_application_slot(groups,
            length(plan.groups_by_application_slot)),
        plan.schedule, plan.model_revision, plan.environment_revision,
        plan.shared_target_plans)
    state.plan_batches = WeakRef(batches)
    return result
end

struct GrowthPlanCompiler
    state::GrowthRecord
end
Base.@nospecializeinfer @noinline function (compiler::GrowthPlanCompiler)(compiled,
    environment_bindings, streams=nothing, retention=nothing, constants=nothing)
    @nospecialize compiled environment_bindings streams retention constants
    state = compiler.state
    plan = Lean.compile_lean_execution_plan(compiled, environment_bindings,
        streams, retention, constants; state_strategy=state.state_strategy,
        record=state.lean_record)
    state.rich_targets_constructed += state.lean_record.constructed_rich_targets
    return _wrap_plan(plan, state)
end

"""Current logical application rows, without copying scientific values."""
function _batch_ids(group)
    ids = PSE.ObjectId[]
    for batch in group.batches
        append!(ids, batch.row_ids)
    end
    return ids
end

function _same_publication(batch, publication)
    previous = batch.inner.output_publication
    return previous.enabled == publication.enabled &&
        previous.variables == publication.variables
end

function _reuse_guard(group, application, environment_bindings, retention,
    constants, changed_targets)
    publication = PSE._compiled_output_publication(retention, application)
    for batch in group.batches
        batch isa GrowingLeanBatch || return false
        batch.inner.application.plan === application.plan || return false
        isempty(batch.row_ids) && return false
        any(id -> (application.id, id) in changed_targets, batch.row_ids) && return false
        _same_publication(batch, publication) || return false
        typeof(batch.inner.kernel.context.constants) === typeof(constants) || return false
        provider = Lean._provider(environment_bindings, application, first(batch.row_ids))
        provider === batch.inner.environment_provider || return false
    end
    return true
end

function _rebind!(batch::GrowingLeanBatch, application, compiled,
    environment_bindings, streams, retention, constants)
    inner = batch.inner
    inner.application = application
    inner.targets = Lean.LeanTargetView(batch.row_ids, compiled,
        environment_bindings, application, streams, retention, constants,
        batch.state.lean_record)
    context = inner.kernel.context
    context.compiled = compiled
    context.environment_bindings = environment_bindings
    context.application = application
    context.object_id = first(batch.row_ids)
    context.temporal_streams = streams
    context.output_retention = retention
    context.constants = constants
    return nothing
end

function _owner_indices(column, count)
    if column isa Vector
        return (owner=column, indices=1:count)
    elseif column isa SubArray && parent(column) isa Vector
        indices = only(parentindices(column))
        indices = indices isa Base.Slice ? indices.indices : indices
        all(index -> index isa Integer, indices) || return nothing
        return (owner=parent(column), indices=indices[1:count])
    end
    return nothing
end

function _merge_column(left, nleft, right, nright)
    old = _owner_indices(left, nleft)
    new = _owner_indices(right, nright)
    (isnothing(old) || isnothing(new)) && return nothing
    old.owner === new.owner || return nothing
    if old.indices == (1:nleft) && new.indices == ((nleft + 1):(nleft + nright))
        return old.owner
    end
    return view(old.owner, vcat(collect(old.indices), collect(new.indices)))
end

"""
Coalesce only compatible shared-model cohorts. Arrays keep their canonical
owners and exact physical indices; appending a header never copies a scalar.
The old payload remains unmodified until the new plan is installed.
"""
function _coalesce(left::GrowingLeanBatch, right::GrowingLeanBatch, application,
    compiled, environment_bindings, streams, retention, constants)
    a, b = left.inner, right.inner
    a.native == b.native || return nothing
    a.environment_provider === b.environment_provider || return nothing
    a.output_publication.variables == b.output_publication.variables || return nothing
    ka, kb = a.kernel, b.kernel
    ka.models isa GP.SharedColumnModel && kb.models isa GP.SharedColumnModel || return nothing
    ka.models.model === kb.models.model || return nothing
    typeof(ka.context) === typeof(kb.context) || return nothing
    if a.native
        names = keys(a.data.arrays)
        names == keys(b.data.arrays) || return nothing
        merged = map(names) do name
            _merge_column(getproperty(a.data.arrays, name), a.data.nrows,
                getproperty(b.data.arrays, name), b.data.nrows)
        end
        any(isnothing, merged) && return nothing
        arrays = NamedTuple{names}(merged)
        data = GP.ColumnData(arrays, a.data.recipe, a.data.nrows + b.data.nrows)
    else
        names = keys(a.data.references)
        names == keys(b.data.references) || return nothing
        columns = map(names) do name
            old, new = getproperty(a.data.references, name), getproperty(b.data.references, name)
            eltype(old) === eltype(new) || return nothing
            vcat(old, new)
        end
        any(isnothing, columns) && return nothing
        data = CR.RegionReferenceData(NamedTuple{names}(columns), a.data.nrows + b.data.nrows)
    end
    publish = a.output_publication.enabled
    publish == b.output_publication.enabled || return nothing
    bindings = if publish
        eltype(ka.output_bindings) === eltype(kb.output_bindings) || return nothing
        vcat(ka.output_bindings, kb.output_bindings)
    else
        nothing
    end
    kernel = GP.ColumnKernel{publish,typeof(ka.models),typeof(ka.context),
        Nothing,typeof(bindings)}(ka.models, ka.context, nothing, bindings)
    ids = vcat(left.row_ids, right.row_ids)
    targets = Lean.LeanTargetView(ids, compiled, environment_bindings,
        application, streams, retention, constants, left.state.lean_record)
    inner = Driver.LeanNumericalBatch(application, targets, kernel, data,
        a.environment_provider, a.output_publication, a.counters, a.native)
    return _wrap(inner, left.state)
end

function _lower(application, compiled, environment_bindings, streams,
    retention, constants, state)
    selected = Lean._lower_application(compiled, environment_bindings,
        application, streams, retention, constants, state.state_strategy,
        state.lean_record)
    selected.reason === :eligible || return selected
    batches = PSE.AbstractExecutionBatch[_wrap(batch, state) for batch in selected.batches]
    return (reason=:eligible, batches)
end

function _append_group(group, application, compiled, environment_bindings,
    streams, retention, constants, state, changed_targets)
    _reuse_guard(group, application, environment_bindings, retention,
        constants, changed_targets) || return nothing
    previous_ids = _batch_ids(group)
    current_ids = application.target_ids
    length(current_ids) >= length(previous_ids) || return nothing
    current_ids[1:length(previous_ids)] == previous_ids || return nothing
    newborn_ids = current_ids[(length(previous_ids) + 1):end]
    all(id -> id in state.added_ids, newborn_ids) || return nothing
    if isempty(newborn_ids)
        return (batches=PSE.AbstractExecutionBatch[group.batches...],
            appended_rows=0, coalesced=0, reused=length(group.batches), lowered=0)
    end
    partial = PSE.CompiledModelApplication(application.plan, copy(newborn_ids))
    selected = _lower(partial, compiled, environment_bindings, streams,
        retention, constants, state)
    selected.reason === :eligible || return nothing
    batches = PSE.AbstractExecutionBatch[group.batches...]
    coalesced = 0
    for batch in selected.batches
        merged = isempty(batches) ? nothing : _coalesce(last(batches), batch,
            application, compiled, environment_bindings, streams, retention, constants)
        if isnothing(merged)
            push!(batches, batch)
        else
            batches[end] = merged
            coalesced += 1
        end
    end
    length(batches) <= 256 || return nothing
    return (batches, appended_rows=length(newborn_ids), coalesced,
        reused=length(group.batches), lowered=length(selected.batches))
end

function _ordinary_group(previous_group, application, compiled,
    environment_bindings, streams, retention, constants, performance,
    changed_application_ids, changed_by_application, shared_plan_cache)
    if !isnothing(previous_group) && !isnothing(changed_application_ids)
        if !(application.id in changed_application_ids)
            control = PSE._stage_model_execution_group_control_refresh(previous_group,
                compiled, environment_bindings, streams, retention, constants)
            if control !== false
                isnothing(control) || PSE._commit_model_execution_group_control_refresh!(control)
                return (group=previous_group, targets_constructed=0,
                    batches_constructed=0, reused=true)
            end
        else
            delta = PSE._refresh_model_execution_group_delta!(previous_group,
                compiled, environment_bindings, application, streams, retention,
                constants, performance, get(changed_by_application, application.id, ()),
                shared_plan_cache)
            isnothing(delta) || return (; delta..., reused=false)
        end
    end
    targets = Any[PSE._compiled_model_execution_target(compiled,
        environment_bindings, application, id, streams, retention, constants;
        shared_plan_cache) for id in application.target_ids]
    batches = PSE.AbstractExecutionBatch[]
    PSE._append_model_execution_batches!(batches, environment_bindings,
        application, targets, retention)
    group = isempty(batches) ? nothing :
        PSE.CompiledApplicationExecutionGroup(application, batches)
    return (group, targets_constructed=length(targets),
        batches_constructed=length(batches), reused=false)
end

function _invalidate!(state, reason)
    if !state.disabled
        state.full_invalidations += 1
        state.disabled = true
        state.plan_batches = nothing
        empty!(state.added_ids)
        state.pending_addition = false
        push!(state.reasons, (event=:ordinary_fallback, reason))
    end
    return nothing
end

Base.@nospecializeinfer @noinline function PSE._try_refresh_execution_batch_plan(
    trigger::GrowingLeanBatch, previous, compiled, environment_bindings,
    streams, retention, constants, performance, changed_application_ids,
    changed_targets,
)
    @nospecialize previous compiled environment_bindings streams retention constants performance changed_application_ids changed_targets
    state = trigger.state
    state.disabled && return nothing
    state.plan_batches isa WeakRef && state.plan_batches.value === previous.batches ||
        return _invalidate!(state, :unobserved_plan_epoch)
    state.captured_token == _model_token(compiled.model) && state.pending_addition ||
        return _invalidate!(state, :not_observed_pure_addition)
    compiled.status_view_refresh_is_pure_addition ||
        return _invalidate!(state, :semantic_refresh_not_pure_addition)
    isnothing(performance) || return _invalidate!(state, :instrumented_execution)
    # A successful callback must understand every old alternative. In
    # particular, direct-call leases cannot be silently kept by this compiler.
    all(batch -> batch isa PSE.CompiledExecutionBatch ||
        (batch isa GrowingLeanBatch && batch.state === state), previous.batches) ||
        return _invalidate!(state, :unknown_alternative_batch)

    previous_groups = Dict(group.application.id => group for group in previous.groups)
    changed_by_application = PSE._changed_execution_target_ids_by_application(changed_targets)
    manual = PSE._manual_call_application_ids(compiled)
    groups = PSE.CompiledApplicationExecutionGroup[]
    batches = PSE.AbstractExecutionBatch[]
    rebindings = Tuple{GrowingLeanBatch,Any}[]
    rich = new_batches = reused_groups = 0
    reused_numeric = reused_numeric_groups = appended = merged_count = rebuilt_numeric = 0
    ordinary_rebuilt = ordinary_reused = 0

    for application in PSE._ordered_model_applications(compiled)
        application.id in manual && continue
        old = get(previous_groups, application.id, nothing)
        old_numeric = !isnothing(old) && all(batch -> batch isa GrowingLeanBatch, old.batches)
        selected = nothing
        if old_numeric && !isnothing(changed_application_ids)
            selected = _append_group(old, application, compiled,
                environment_bindings, streams, retention, constants, state, changed_targets)
        end
        if !isnothing(selected)
            chosen = selected.batches
            reused_numeric += selected.reused
            reused_numeric_groups += 1
            appended += selected.appended_rows
            merged_count += selected.coalesced
            new_batches += selected.lowered
        else
            unchanged_ordinary = !isnothing(old) && !old_numeric &&
                !isnothing(changed_application_ids) && !(application.id in changed_application_ids)
            fresh = unchanged_ordinary ? (reason=:unchanged_ordinary, batches=nothing) :
                _lower(application, compiled, environment_bindings, streams, retention, constants, state)
            if fresh.reason === :eligible
                chosen = fresh.batches
                rebuilt_numeric += length(chosen)
                new_batches += length(chosen)
                appended += sum(count(id -> id in state.added_ids, batch.row_ids)
                    for batch in chosen; init=0)
            else
                ordinary = _ordinary_group(old_numeric ? nothing : old, application,
                    compiled, environment_bindings, streams, retention, constants,
                    performance, changed_application_ids, changed_by_application,
                    previous.shared_target_plans)
                rich += ordinary.targets_constructed
                new_batches += ordinary.batches_constructed
                ordinary.reused ? (ordinary_reused += 1; reused_groups += 1) :
                    (ordinary_rebuilt += 1)
                isnothing(ordinary.group) && continue
                push!(groups, ordinary.group)
                append!(batches, ordinary.group.batches)
                continue
            end
        end
        isempty(chosen) && continue
        for batch in chosen
            push!(rebindings, (batch, application))
        end
        push!(groups, PSE.CompiledApplicationExecutionGroup(application,
            Lean._bounded_application_batches(chosen)))
        append!(batches, chosen)
    end

    # All capability checks precede rebinding the retained numerical headers.
    for (batch, application) in rebindings
        _rebind!(batch, application, compiled, environment_bindings,
            streams, retention, constants)
    end
    plan = PSE.CompiledExecutionPlan(groups, batches,
        PSE._execution_groups_by_application_slot(groups,
            length(compiled.scenario_plan.applications)),
        previous.schedule, compiled.revision,
        environment_bindings.environment_revision, previous.shared_target_plans)
    state.plan_batches = WeakRef(batches)
    state.pending_addition = false
    state.incremental_refreshes += 1
    state.reused_batches += reused_numeric
    state.reused_numeric_groups += reused_numeric_groups
    state.appended_rows += appended
    state.coalesced_batches += merged_count
    state.rebuilt_numeric_batches += rebuilt_numeric
    state.rebuilt_ordinary_groups += ordinary_rebuilt
    state.reused_ordinary_groups += ordinary_reused
    state.rich_targets_constructed += rich
    push!(state.reasons, (event=:incremental_addition, added_objects=length(state.added_ids),
        appended_rows=appended, reused_numeric_batches=reused_numeric,
        rebuilt_numeric_batches=rebuilt_numeric))
    return (plan, targets_constructed=rich, batches_constructed=new_batches,
        groups_reused=reused_groups + reused_numeric_groups)
end

"""
    prepare_growth(model; steps=0, outputs=:none, state_strategy=:native)

Opt-in direct lean compiler with strictly guarded addition refresh. The return
value is an ordinary Simulation advanced with public continue!/step!. Unknown
mutations and instrumentation keep the full ordinary execution path.
"""
Base.@nospecializeinfer @noinline function prepare_growth(model::PSE.CompositeModel;
    steps::Integer=0, outputs=:none, performance::Bool=false,
    state_strategy::Symbol=:native, constants=PSE.PlantMeteo.Constants())
    @nospecialize model outputs constants
    steps >= 0 || throw(ArgumentError("steps must be nonnegative"))
    state_strategy in (:native, :references) || throw(ArgumentError("Unknown state strategy"))
    state_strategy === :native && !(model.status_storage isa PSE.NativeColumnStorage) &&
        throw(ArgumentError("Native growth execution needs native allocation from construction"))
    state = GrowthRecord(model, state_strategy)
    compiler = performance ? PSE.compile_model_execution_plan : GrowthPlanCompiler(state)
    simulation = PSE.run!(model; steps=0, constants, outputs, performance,
        _execution_plan_compiler=compiler)
    state.captured_token = _model_token(model)
    if performance
        state.disabled = true
        state.rich_targets_constructed = sum(length(batch.targets)
            for batch in simulation.execution_plan.batches; init=0)
        push!(state.reasons, (event=:ordinary_fallback, reason=:performance_instrumentation))
    end
    _reports[simulation] = state
    steps == 0 || PSE.continue!(simulation; steps)
    return simulation
end

function growth_report(simulation::PSE.Simulation)
    state = get(_reports, simulation, nothing)
    isnothing(state) && throw(ArgumentError("Simulation was not prepared by prepare_growth"))
    total(name) = sum(getfield(counter, name) for counter in state.counters; init=0)
    live = [batch for batch in simulation.execution_plan.batches if batch isa GrowingLeanBatch]
    return (strategy=:direct_lean_incremental_addition,
        driver_batch_executions=total(:driver_batches),
        driver_row_executions=total(:driver_rows), native_row_executions=total(:native_rows),
        executed_native_column_fields=total(:native_fields),
        native_newborn_row_executions=state.native_newborn_row_executions,
        incremental_refreshes=state.incremental_refreshes,
        reused_batches=state.reused_batches, reused_numeric_groups=state.reused_numeric_groups,
        appended_rows=state.appended_rows, coalesced_batches=state.coalesced_batches,
        rebuilt_numeric_batches=state.rebuilt_numeric_batches,
        rebuilt_ordinary_groups=state.rebuilt_ordinary_groups,
        reused_ordinary_groups=state.reused_ordinary_groups,
        rich_targets_constructed=state.rich_targets_constructed,
        full_invalidations=state.full_invalidations, live_lean_batches=length(live),
        live_native_rows=sum(batch.inner.native ? length(batch.row_ids) : 0
            for batch in live; init=0),
        lazy_target_snapshots=state.lean_record.lazy_target_snapshots,
        initial_skipped_rich_targets=state.lean_record.skipped_rich_targets,
        source_facades_current=all(batch ->
            batch.targets.compiled === simulation.compiled &&
            batch.targets.environment_bindings === simulation.environment_bindings &&
            batch.targets.output_retention === simulation.output_retention, live),
        disabled=state.disabled, numerical_scalar_copies=false,
        fallback_policy=:ordinary_for_nonaddition_unknown_or_consumed_refresh,
        reasons=copy(state.reasons))
end

end # module
