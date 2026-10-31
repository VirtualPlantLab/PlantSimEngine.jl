module DirectPlanConstruction

using PlantSimEngine
const PSE = PlantSimEngine
const Native = Main.NativePBDriver
const Lean = Main.LeanNativeCompiler
const Direct = Main.DirectCallCompiler
const Shared = Main.SharedCallProgram
const Tight = Main.TightCallProgram

export prepare_selected_plan, compile_selected_plan, selected_plan_report,
    SelectedTightBatch, SelectedTargetView

mutable struct SelectedRecord
    shared::Shared.SharedRecord
    counts::Union{Nothing,Tight.TightCounters}
    logical_views::Int
    selected_batches::Int
    selected_rows::Int
    tight_frames::Int
    ordinary_batches::Int
    ordinary_targets::Int
    batch_entries::Int
    fallback_entries::Int
    fallback_materializations::Int
    header_strategy::Symbol
    reasons::Vector{NamedTuple}
end
SelectedRecord(counts, header) = SelectedRecord(Shared.SharedRecord(), counts,
    0, 0, 0, 0, 0, 0, 0, 0, 0, header, NamedTuple[])
const _records = WeakKeyDict{Any,SelectedRecord}()

# No full-protocol context, row lease or owner is stored before an actual
# inspection/fallback. A failed row records the ordinary epoch boundary:
# entered rows use partial_time, later rows retain last_time.
mutable struct FallbackFactory
    program::Any
    status_strategy::Symbol
    shared_batch::Any
    targets::Any
    last_time::Float64
    partial_time::Union{Nothing,Float64}
    entered::Int
    active::Bool
    record::SelectedRecord
end

struct SelectedTargetView <: AbstractVector{Any}
    batch::Any
    ids::Vector{PSE.ObjectId}
end
Base.IndexStyle(::Type{SelectedTargetView}) = IndexLinear()
Base.size(targets::SelectedTargetView) = size(targets.ids)
Base.length(targets::SelectedTargetView) = length(targets.ids)
PSE._model_execution_target_id(targets::SelectedTargetView, index) = targets.ids[index]
Base.getindex(targets::SelectedTargetView, index::Int) =
    _full_protocol!(targets.batch).targets[index]

struct SelectedTightBatch{F,H,K,A,E,O} <: PSE.AbstractExecutionBatch
    frame::F
    headers::H
    counts::K
    application::A
    environment_provider::E
    output_publication::O
    factory::FallbackFactory
end
@inline function Base.getproperty(batch::SelectedTightBatch, name::Symbol)
    name === :targets && return getfield(batch, :factory).targets
    return getfield(batch, name)
end
Base.propertynames(batch::SelectedTightBatch, private::Bool=false) =
    private ? (fieldnames(typeof(batch))..., :targets) :
        (:application, :environment_provider, :output_publication, :targets)
PSE._execution_batch_requires_full_refresh(::SelectedTightBatch) = true

_node_count(program) = 1 + sum(_node_count, values(program.children); init=0)

"""Materialize the tested full protocol once, using current canonical state."""
Base.@nospecializeinfer @noinline function _full_protocol!(batch::SelectedTightBatch)
    @nospecialize batch
    factory = batch.factory
    factory.active = false
    factory.shared_batch === nothing || return factory.shared_batch
    program = factory.program
    rows = program.rows
    record = factory.record
    leases = Direct.DirectRowLease[
        Direct.DirectRowLease(record.shared.counters) for _ in rows.ids]
    state = Shared.SharedProgramState(0, leases, record.shared)
    frame = Shared._frame(program, state, factory.status_strategy, rows.constants)
    if factory.partial_time === nothing
        Tight._seed_frame_time!(frame, factory.last_time, true)
    else
        Tight._seed_partial_frame_time!(frame, factory.entered,
            factory.partial_time, factory.last_time, true)
    end
    inner = Shared.SharedProgramBatch(frame, Shared.SharedTargetView(frame, rows.ids),
        batch.application, batch.environment_provider, batch.output_publication,
        rows.compiled, rows.environment, rows.streams, rows.retention,
        rows.constants, record.shared)
    factory.shared_batch = inner
    record.shared.row_leases += length(leases)
    record.fallback_materializations += 1
    return inner
end

@inline function _selected_entry_current(batch, compiled, environment)
    rows = batch.frame.program.rows
    return batch.factory.active && compiled === rows.compiled &&
        environment === rows.environment && PSE._active_call_evaluation() === nothing
end

@noinline function _selected_numerical_rows!(batch::SelectedTightBatch,
    environment, constants, time)
    program = batch.frame.program
    publish = batch.output_publication.enabled
    entered = 0
    try
        for row in eachindex(program.rows.ids)
            entered = row
            context = Tight.TightContext(batch.frame, row, float(time), constants,
                Tight._header(batch.headers, row), batch.counts)
            model = Tight._model(batch.frame, row)
            view = @inbounds program.views[row]
            Tight._count_root!(batch.counts, view)
            Base.@inline PSE.run!(model, Tight._status(context, model),
                environment, constants, context)
            publish && PSE._model_publish_runtime_outputs!(program.outputs[row], time)
        end
    catch
        # Do not run scientific code or allocate full-protocol frames while
        # unwinding. A later inspection/refresh seeds the exact row epochs.
        batch.factory.partial_time = float(time)
        batch.factory.entered = entered
        batch.factory.active = false
        rethrow()
    end
    batch.factory.last_time = float(time)
    return nothing
end

Base.@nospecializeinfer @noinline function PSE._run_model_execution_batch!(
    batch::SelectedTightBatch, compiled::PSE.CompiledCompositeModel,
    environment::PSE.CompiledEnvironmentBindings, time::Real,
    constants, streams, retention,
)
    @nospecialize compiled environment constants streams retention
    if !_selected_entry_current(batch, compiled, environment)
        batch.factory.record.fallback_entries += 1
        inner = _full_protocol!(batch)
        return PSE._run_model_execution_batch!(inner, compiled, environment,
            time, constants, streams, retention)
    end
    sampled = PSE._model_execution_batch_environment(batch.environment_provider,
        environment, batch.application, time)
    batch.factory.record.batch_entries += 1
    _selected_numerical_rows!(batch, sampled, constants, time)
    return nothing
end

function PSE._compiled_source_prepare_batch(simulation::PSE.Simulation,
    batch::SelectedTightBatch, time::Real)
    # Source execution requests real owners via the target facade and therefore
    # permanently enters full protocol before invoking its generated kernels.
    sampled = PSE._model_execution_batch_environment(batch.environment_provider,
        simulation.environment_bindings, batch.application, time)
    return sampled, batch.output_publication.enabled
end
function PSE._explain_execution_batch(batch::SelectedTightBatch, index)
    program = batch.frame.program
    return (batch_index=index, application_id=batch.application.id,
        process=batch.application.process,
        object_ids=[id.value for id in program.rows.ids],
        batch_size=length(program.rows.ids), target_type=SelectedTargetView,
        model_type=typeof(Shared._model(program, 1)), status_type=eltype(program.views),
        input_bindings_type=Tuple{}, call_bindings_type=typeof(first(program.rows.call_bindings)),
        call_capability=Tight._TIGHT_CAPABILITY,
        output_variables=batch.output_publication.variables,
        output_publication=batch.output_publication.enabled ? :direct_stream_bindings : :none,
        environment_binding_type=typeof(batch.environment_provider),
        inner_loop_dispatch=:direct_selected_private_typed_program,
        fallback_materialized=batch.factory.shared_batch !== nothing)
end

function PSE._capture_execution_batch_refresh_state!(batch::SelectedTightBatch, model)
    PSE._capture_execution_batch_refresh_state!(_full_protocol!(batch), model)
    return nothing
end
Base.@nospecializeinfer @noinline function PSE._try_refresh_execution_batch_plan(
    trigger::SelectedTightBatch, previous, compiled, environment, streams, retention,
    constants, performance, changed_applications, changed_targets,
)
    @nospecialize previous compiled environment streams retention constants performance changed_applications changed_targets
    all(batch -> batch isa PSE.CompiledExecutionBatch || batch isa SelectedTightBatch,
        previous.batches) || return nothing
    groups = PSE.CompiledApplicationExecutionGroup[]
    batches = PSE.AbstractExecutionBatch[]
    for group in previous.groups
        selected = PSE.AbstractExecutionBatch[]
        for batch in group.batches
            batch isa SelectedTightBatch ?
                append!(selected, Shared._retired_batches(_full_protocol!(batch))) :
                push!(selected, batch)
        end
        push!(groups, PSE.CompiledApplicationExecutionGroup(group.application, selected))
        append!(batches, selected)
    end
    shadow = PSE.CompiledExecutionPlan(groups, batches,
        PSE._execution_groups_by_application_slot(groups, length(previous.groups_by_application_slot)),
        previous.schedule, previous.model_revision, previous.environment_revision,
        previous.shared_target_plans)
    return PSE._refresh_model_execution_plan(shadow, compiled, environment, streams,
        retention, constants, performance, changed_applications, changed_targets)
end

# Test source capabilities against logical bindings before numerical projection.
# Unknown public-context graphs take ordinary execution immediately, without
# constructing a Shared frame merely to reject the private protocol afterward.
Base.@nospecializeinfer @noinline function _tight_capability(compiled, application, id, ancestors)
    @nospecialize compiled application
    key = (application.id, id)
    key in ancestors && return false
    model = PSE._application_model(application, id)
    Tight.tight_call_effects(typeof(model)) === Tight._TIGHT_CAPABILITY || return false
    push!(ancestors, key)
    try
        for binding in get(compiled.call_bindings_by_target, key, ())
            PSE._compiled_call_mode(binding) === :manual || return false
            binding.multiplicity === :many && return false
            length(binding.callee_application_ids) == length(binding.callee_object_ids) == 1 || return false
            child = PSE._compiled_application_by_id(compiled, only(binding.callee_application_ids))
            child_id = only(binding.callee_object_ids)
            PSE._call_binding_target_matches(binding, child, child_id) || return false
            _tight_capability(compiled, child, child_id, ancestors) || return false
        end
        return true
    finally
        delete!(ancestors, key)
    end
end

Base.@nospecializeinfer @noinline function _lower_selected(compiled, environment,
    application, streams, retention, constants, state_strategy, status_strategy,
    header_strategy, record)
    @nospecialize compiled environment application streams retention constants
    isempty(application.target_ids) && return (reason=:empty_application, batches=nothing)
    for id in application.target_ids
        _tight_capability(compiled, application, id,
            Set{Tuple{Symbol,PSE.ObjectId}}()) ||
                return (reason=:full_call_protocol_required, batches=nothing)
    end
    blueprints = Any[]
    try
        for id in application.target_ids
            push!(blueprints, Shared._blueprint(compiled, environment, application, id,
                streams, retention, constants, state_strategy,
                Set{Tuple{Symbol,PSE.ObjectId}}()))
        end
    catch error
        error isa ArgumentError || rethrow()
        return (reason=Symbol(error.msg), batches=nothing)
    end
    ranges = UnitRange{Int}[]
    start = 1
    for index in 2:length(blueprints)
        blueprints[index].shape == blueprints[index-1].shape && continue
        push!(ranges, start:index-1)
        start = index
    end
    push!(ranges, start:length(blueprints))
    # Validate every cohort before constructing private frames or crediting
    # selected work. One rejected union must leave the entire application's
    # prepared counters at zero, even when an earlier cohort was eligible.
    choices = Any[]
    for selected in ranges
        subset = blueprints[selected]
        program = Shared._program(subset, compiled, environment, streams,
            retention, constants, record.shared)
        Tight._eligible(program) || return (reason=:full_call_protocol_required, batches=nothing)
        headers = header_strategy === :projected ? Tight.ProjectedHeaders() :
            Tight._union_headers(program, status_strategy)
        headers === nothing && return (
            reason=:union_header_requires_identical_canonical_status, batches=nothing)
        push!(choices, (program=program, headers=headers, provider=first(subset).provider))
    end
    batches = PSE.AbstractExecutionBatch[]
    publication = PSE._compiled_output_publication(retention, application)
    for choice in choices
        program = choice.program
        headers = choice.headers
        factory = FallbackFactory(program, status_strategy, nothing, nothing,
            0.0, nothing, 0, true, record)
        frame = Tight._frame(program, status_strategy)
        batch = SelectedTightBatch(frame, headers, record.counts, application,
            choice.provider, publication, factory)
        factory.targets = SelectedTargetView(batch, program.rows.ids)
        push!(batches, batch)
        record.selected_batches += 1
        record.selected_rows += length(program.rows.ids)
        record.tight_frames += _node_count(program)
        record.shared.cohorts += 1
    end
    return (reason=:eligible, batches)
end

struct SelectedPlanCompiler
    state_strategy::Symbol
    status_strategy::Symbol
    header_strategy::Symbol
    record::SelectedRecord
end
Base.@nospecializeinfer @noinline function (compiler::SelectedPlanCompiler)(compiled,
    environment, streams=nothing, retention=nothing, constants=nothing)
    @nospecialize compiled environment streams retention constants
    return compile_selected_plan(compiled, environment, streams, retention, constants;
        state_strategy=compiler.state_strategy, status_strategy=compiler.status_strategy,
        header_strategy=compiler.header_strategy, record=compiler.record)
end
Base.@nospecializeinfer @noinline function compile_selected_plan(compiled, environment,
    streams=nothing, retention=nothing, constants=nothing;
    state_strategy=:references, status_strategy=:refs, header_strategy=:projected,
    record=SelectedRecord(nothing, header_strategy))
    @nospecialize compiled environment streams retention constants
    groups = PSE.CompiledApplicationExecutionGroup[]
    batches = PSE.AbstractExecutionBatch[]
    record.logical_views = length(compiled.status_views_by_target)
    manual = PSE._manual_call_application_ids(compiled)
    shared = compiled.execution_policy.shared_plans ? IdDict{Any,Any}() : nothing
    for application in PSE._ordered_model_applications(compiled)
        application.id in manual && continue
        chosen = _lower_selected(compiled, environment, application, streams, retention,
            constants, state_strategy, status_strategy, header_strategy, record)
        first_batch = length(batches) + 1
        if chosen.reason === :eligible
            append!(batches, chosen.batches)
        else
            targets = Any[PSE._compiled_model_execution_target(compiled, environment,
                application, id, streams, retention, constants; shared_plan_cache=shared)
                for id in application.target_ids]
            record.ordinary_targets += length(targets)
            PSE._append_model_execution_batches!(batches, environment, application, targets, retention)
            record.ordinary_batches += length(batches) - first_batch + 1
        end
        push!(record.reasons, (application=application.id,
            targets=length(application.target_ids), reason=chosen.reason))
        first_batch > length(batches) && continue
        selected = batches[first_batch:end]
        chosen.reason === :eligible && (selected = Lean._bounded_application_batches(selected))
        push!(groups, PSE.CompiledApplicationExecutionGroup(application, selected))
    end
    return PSE.CompiledExecutionPlan(groups, batches,
        PSE._execution_groups_by_application_slot(groups, length(compiled.scenario_plan.applications)),
        PSE._runtime_application_schedule(compiled.scenario_plan.application_schedule),
        compiled.revision, environment.environment_revision, shared)
end

Base.@nospecializeinfer @noinline function prepare_selected_plan(model::PSE.CompositeModel;
    steps::Integer=0, outputs=:none, performance::Bool=false,
    state_strategy::Symbol=:references, status_strategy::Symbol=:refs,
    header_strategy::Symbol=:projected, count_calls::Bool=false,
    constants=PSE.PlantMeteo.Constants())
    @nospecialize model outputs constants
    state_strategy in (:references, :native) || throw(ArgumentError("Unknown state strategy"))
    status_strategy in (:refs, :direct) || throw(ArgumentError("Unknown status strategy"))
    header_strategy in (:projected, :same_object_union) || throw(ArgumentError("Unknown header strategy"))
    state_strategy === :native && !(model.status_storage isa PSE.NativeColumnStorage) &&
        throw(ArgumentError("Native state requires canonical native allocation"))
    steps >= 0 || throw(ArgumentError("steps must be nonnegative"))
    record = SelectedRecord(count_calls ? Tight.TightCounters() : nothing, header_strategy)
    compiler = performance ? PSE.compile_model_execution_plan :
        SelectedPlanCompiler(state_strategy, status_strategy, header_strategy, record)
    simulation = PSE.run!(model; steps=0, outputs, performance, constants,
        _execution_plan_compiler=compiler)
    _records[simulation] = record
    steps == 0 || PSE.continue!(simulation; steps)
    return simulation
end

function selected_plan_report(simulation::PSE.Simulation)
    record = get(_records, simulation, nothing)
    record === nothing && throw(ArgumentError("Simulation was not prepared by prepare_selected_plan"))
    counts = record.counts
    shared = record.shared
    return (selected_batches_prepared=record.selected_batches,
        selected_rows_prepared=record.selected_rows, tight_frames_prepared=record.tight_frames,
        batch_executions=record.batch_entries, fallback_batch_executions=record.fallback_entries,
        executed_numerical_roots=counts === nothing ? missing : counts.roots,
        executed_numerical_calls=counts === nothing ? missing : counts.calls,
        typed_model_lookups=counts === nothing ? missing : counts.lookups,
        executed_numerical_fields=counts === nothing ? missing : counts.fields,
        executed_native_column_fields=counts === nothing ? missing : counts.native_fields,
        shared_frames_materialized=shared.shared_contexts,
        fallback_programs_materialized=record.fallback_materializations,
        lazy_public_wrappers=shared.lazy_wrappers,
        constructed_rich_targets=record.ordinary_targets + shared.counters.rich_targets,
        ordinary_targets_prepared=record.ordinary_targets,
        ordinary_batches_prepared=record.ordinary_batches,
        logical_views=record.logical_views, program_nodes=shared.program_nodes,
        live_selected_batches=count(batch -> batch isa SelectedTightBatch && batch.factory.active,
            simulation.execution_plan.batches),
        full_shared_numerical_roots=shared.counters.roots,
        full_shared_numerical_calls=shared.counters.calls,
        source_capability=Tight._TIGHT_CAPABILITY,
        scientific_kernels=:original, numerical_scalar_copies=false,
        counters=counts === nothing ? :compiled_out : :actual_work_companion,
        header_strategy=record.header_strategy,
        preparation=:direct_selected_program_with_lazy_full_protocol,
        refresh_policy=:materialize_original_owner_tree_then_ordinary_refresh,
        reasons=copy(record.reasons))
end

end # module
