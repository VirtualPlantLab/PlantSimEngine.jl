module LeanNativeCompiler

using PlantSimEngine

const PSE = PlantSimEngine
const CR = Main.CompiledRegionsExperiment
if !isdefined(Main, :LeanNativeDriver)
    Base.include(Main, joinpath(@__DIR__, "lean_driver.jl"))
end
const Driver = Main.LeanNativeDriver

export prepare_lean, lean_report, compile_lean_execution_plan, LeanTargetView

mutable struct LeanCompilationRecord
    logical_status_views::Int
    skipped_rich_targets::Int
    constructed_rich_targets::Int
    lazy_target_snapshots::Int
    lean_batches::Int
    contexts::Int
    counters::Vector{Driver.LeanDriverCounters}
    reasons::Vector{NamedTuple}
end
LeanCompilationRecord() = LeanCompilationRecord(0, 0, 0, 0, 0, 0,
    Driver.LeanDriverCounters[], NamedTuple[])

# Reports retain counters/metadata only. The weak key does not keep completed
# simulations, their columns, environments or logical compiler graphs alive.
const _reports = WeakKeyDict{Any,LeanCompilationRecord}()

"""
Cold logical-target facade. Numerical execution never indexes this collection.
Inspection APIs can still request an ordinary target snapshot without requiring
one eagerly for every selected object. The factory's scene fields are erased.
"""
struct LeanTargetView <: AbstractVector{Any}
    object_ids::Vector{PSE.ObjectId}
    compiled::Any
    environment_bindings::Any
    application::Any
    temporal_streams::Any
    output_retention::Any
    constants::Any
    record::LeanCompilationRecord
end
Base.size(targets::LeanTargetView) = size(targets.object_ids)
Base.length(targets::LeanTargetView) = length(targets.object_ids)
Base.IndexStyle(::Type{LeanTargetView}) = IndexLinear()
function Base.getindex(targets::LeanTargetView, index::Int)
    id = targets.object_ids[index]
    target = PSE._compiled_model_execution_target(targets.compiled,
        targets.environment_bindings, targets.application, id,
        targets.temporal_streams, targets.output_retention, targets.constants)
    targets.record.lazy_target_snapshots += 1
    return target
end
PSE._model_execution_target_id(targets::LeanTargetView, index) = targets.object_ids[index]

# Any lifecycle/model/environment change takes the existing transactional rich
# rebuild. The live schedule, canonical references and histories survive, and
# applications later in the same timestep see newly registered objects.
PSE._execution_batch_requires_full_refresh(::Driver.LeanNumericalBatch) = true

function PSE._explain_execution_batch(batch::Driver.LeanNumericalBatch, index)
    models = batch.kernel.models
    model_type = models isa CR.GP.SharedColumnModel ? typeof(models.model) : eltype(models.models)
    ids = batch.targets isa LeanTargetView ? batch.targets.object_ids : batch.targets
    return (batch_index=index, application_id=batch.application.id,
        process=batch.application.process, object_ids=[id.value for id in ids],
        batch_size=length(ids), target_type=LeanTargetView,
        model_type, status_type=typeof(batch.data), input_bindings_type=Tuple{},
        call_bindings_type=Tuple{}, call_capability=:no_calls,
        output_variables=batch.output_publication.variables,
        output_publication=batch.output_publication.enabled ? :direct_stream_bindings : :none,
        environment_binding_type=typeof(batch.environment_provider),
        inner_loop_dispatch=:bounded_model_port_kernel)
end

Base.@nospecializeinfer @noinline function _provider(environment_bindings, application, id)
    @nospecialize environment_bindings application
    binding = PSE._environment_binding_for(environment_bindings, application.id, id)
    isnothing(binding) && return nothing
    binding.backend isa PSE.GlobalConstant || return PSE._UNSPECIFIED_SCENE_ENVIRONMENT
    return binding.uses_raw_global_source ?
        PSE.RawGlobalModelEnvironment(binding.prepared_source) :
        PSE.CachedGlobalModelEnvironment(binding)
end

function _same_physical_owners(left, right)
    length(left) == length(right) || return false
    for (a, b) in zip(left, right)
        a === b || return false
    end
    return true
end

function _model_port_proof(model)
    CR.region_effects(typeof(model)) === :local_ports || return (reason=:unknown_effects,)
    isempty(PSE.environment_outputs_(model)) || return (reason=:environment_commit_boundary,)
    isempty(PSE._distributed_output_schema(model)) || return (reason=:distributed_output_boundary,)
    names = Tuple(unique((keys(PSE.inputs_(model))..., keys(PSE.outputs_(model))...)))
    return (reason=:eligible, names, writes=Tuple(keys(PSE.outputs_(model))))
end

Base.@nospecializeinfer function _owner_signature(status, names)
    @nospecialize status names
    owners = Any[]
    for name in names
        reference = PSE.refvalue(status, name)
        reference isa Base.RefArray || return nothing
        source = getfield(reference, :x)
        source isa Vector && isconcretetype(eltype(source)) && isbitstype(eltype(source)) || return nothing
        push!(owners, source)
    end
    return owners
end

"""Prove one application using only logical/status/environment bindings."""
Base.@nospecializeinfer @noinline function _application_rows(compiled, environment_bindings,
    application, state_strategy)
    @nospecialize compiled environment_bindings application
    isempty(application.target_ids) && return (reason=:empty_application,)
    ids = PSE.ObjectId[]
    models = Any[]
    statuses = Any[]
    signatures = Any[]
    port_names = nothing
    write_names = nothing
    application_id = application.id
    default_model = PSE._application_default_model(application)
    overrides = application.model_overrides
    call_index = compiled.call_bindings_by_target
    status_index = compiled.status_views_by_target
    proofs = IdDict{Any,Any}()
    # The semantic compiler owns one environment plan per application. Like
    # the ordinary homogeneous batch compiler, a global provider samples once
    # at the batch boundary; spatial providers require the ordinary executor.
    provider = _provider(environment_bindings, application, first(application.target_ids))
    provider isa PSE.UnspecifiedModelEnvironment && return (reason=:per_object_environment_boundary,)
    for id in application.target_ids
        model = isnothing(overrides) ? default_model : get(overrides, id, default_model)
        proof = get!(proofs, model) do
            _model_port_proof(model)
        end
        proof.reason === :eligible || return (reason=proof.reason,)
        calls = get(call_index, (application_id, id), ())
        isempty(calls) || return (reason=:manual_or_initializer_calls,)
        status_view = status_index[(application_id, id)]
        isempty(status_view.temporal_inputs) || return (reason=:temporal_input_boundary,)
        isempty(status_view.private_outputs) || return (reason=:private_output_boundary,)
        names, writes = proof.names, proof.writes
        all(name -> hasproperty(status_view.status, name), names) || return (reason=:missing_status_port,)
        if isnothing(port_names)
            port_names, write_names = names, writes
        elseif names != port_names || writes != write_names
            return (reason=:heterogeneous_port_schema,)
        end
        owner_signature = state_strategy === :native ? _owner_signature(status_view.status, names) : ()
        isnothing(owner_signature) && return (reason=:non_native_or_nonscalar_ports,)
        push!(ids, id)
        push!(models, model)
        push!(statuses, status_view.status)
        push!(signatures, (typeof(model), owner_signature))
    end
    return (reason=:eligible, ids, models, statuses, signatures, port_names, provider)
end

Base.@nospecializeinfer @noinline function _lower_application(compiled, environment_bindings,
    application, streams, retention, constants, strategy, record)
    @nospecialize compiled environment_bindings application streams retention constants
    rows = _application_rows(compiled, environment_bindings, application, strategy)
    rows.reason === :eligible || return (reason=rows.reason, batches=nothing)
    ranges = UnitRange{Int}[]
    first_row = 1
    for row in 2:length(rows.ids)
        left, right = rows.signatures[row - 1], rows.signatures[row]
        left[1] === right[1] && _same_physical_owners(left[2], right[2]) && continue
        push!(ranges, first_row:(row - 1))
        first_row = row
    end
    push!(ranges, first_row:length(rows.ids))
    # The dynamic scheduler has no generated tuple per organ, but excessive
    # fragmentation is still a poor plan. Retain ordinary homogeneous rows.
    length(ranges) <= 256 || return (reason=:fragmented_native_cohorts, batches=nothing)
    batches = PSE.AbstractExecutionBatch[]
    try
        for selected in ranges
            ids = rows.ids[selected]
            models, statuses = rows.models[selected], rows.statuses[selected]
            provider = rows.provider
            publication = PSE._compiled_output_publication(retention, application)
            output_bindings = publication.enabled ?
                Any[PSE._runtime_model_output_streams(status, application,
                    id, streams, retention) for (id, status) in zip(ids, statuses)] :
                fill((), length(ids))
            targets = LeanTargetView(ids, compiled, environment_bindings, application,
                streams, retention, constants, record)
            batch = Driver.make_lean_batch(application, ids, models, statuses,
                provider, output_bindings, compiled, environment_bindings, streams,
                retention, constants; state_strategy=strategy, target_view=targets,
                validated_names=rows.port_names)
            push!(batches, batch)
        end
    catch exception
        exception isa ArgumentError || rethrow()
        return (reason=:unsupported_physical_payload, batches=nothing)
    end
    return (reason=:eligible, batches)
end

struct LeanPlanCompiler
    state_strategy::Symbol
    record::LeanCompilationRecord
end

function _bounded_application_batches(batches)
    isempty(batches) && return batches
    T = typeof(first(batches))
    all(batch -> typeof(batch) === T, batches) || return batches
    return T[batch for batch in batches]
end

Base.@nospecializeinfer @noinline function (compiler::LeanPlanCompiler)(compiled,
    environment_bindings, streams=nothing, retention=nothing, constants=nothing)
    @nospecialize compiled environment_bindings streams retention constants
    return compile_lean_execution_plan(compiled, environment_bindings, streams,
        retention, constants; state_strategy=compiler.state_strategy, record=compiler.record)
end

"""
Direct numerical lowering after PSE's complete logical compiler. Eligible rows
never visit `_compiled_model_execution_target` or the ordinary root-context/cache
constructors. Unknown capabilities retain the exact original per-application
compiler, scheduler and publication path.
"""
Base.@nospecializeinfer @noinline function compile_lean_execution_plan(compiled,
    environment_bindings, streams=nothing, retention=nothing, constants=nothing;
    state_strategy::Symbol=:native, record=LeanCompilationRecord())
    @nospecialize compiled environment_bindings streams retention constants
    state_strategy in (:native, :references) || throw(ArgumentError("Unknown lean state strategy"))
    record.logical_status_views = length(compiled.status_views_by_target)
    groups = PSE.CompiledApplicationExecutionGroup[]
    batches = PSE.AbstractExecutionBatch[]
    manual_ids = PSE._manual_call_application_ids(compiled)
    shared_plan_cache = compiled.execution_policy.shared_plans ? IdDict{Any,Any}() : nothing
    for application in PSE._ordered_model_applications(compiled)
        application.id in manual_ids && continue
        selected = _lower_application(compiled, environment_bindings, application,
            streams, retention, constants, state_strategy, record)
        first_batch = length(batches) + 1
        if selected.reason === :eligible
            append!(batches, selected.batches)
            record.skipped_rich_targets += length(application.target_ids)
            record.lean_batches += length(selected.batches)
            record.contexts += length(selected.batches)
            for batch in selected.batches
                push!(record.counters, batch.counters)
            end
        else
            targets = Any[]
            for id in application.target_ids
                push!(targets, PSE._compiled_model_execution_target(compiled,
                    environment_bindings, application, id, streams, retention, constants;
                    shared_plan_cache))
                record.constructed_rich_targets += 1
            end
            PSE._append_model_execution_batches!(batches, environment_bindings,
                application, targets, retention)
        end
        push!(record.reasons, (application=application.id, targets=length(application.target_ids),
            reason=selected.reason))
        first_batch > length(batches) && continue
        application_batches = batches[first_batch:end]
        # Keep the dynamic boundary at one application. A homogeneous payload
        # vector lets the ordinary group loop invoke its numerical leaf
        # directly, without dispatching on the full scene again for each batch.
        selected.reason === :eligible &&
            (application_batches = _bounded_application_batches(application_batches))
        push!(groups, PSE.CompiledApplicationExecutionGroup(application, application_batches))
    end
    return PSE.CompiledExecutionPlan(groups, batches,
        PSE._execution_groups_by_application_slot(groups, length(compiled.scenario_plan.applications)),
        PSE._runtime_application_schedule(compiled.scenario_plan.application_schedule),
        compiled.revision, environment_bindings.environment_revision, shared_plan_cache)
end

"""
    prepare_lean(model; steps=0, outputs=:none, performance=false,
        state_strategy=:native, constants=...)

Opt-in experiment returning an ordinary PSE.Simulation. Use `continue!`/`step!`,
outputs and normal lifecycle APIs unchanged. Instrumented runs use the ordinary
compiler. All logical validation/status views remain; only eligible rich root
execution rows are omitted. No package/scale/object-name predicate is used.
"""
Base.@nospecializeinfer @noinline function prepare_lean(model::PSE.CompositeModel;
    steps::Integer=0, outputs=:none, performance::Bool=false,
    state_strategy::Symbol=:native, constants=PSE.PlantMeteo.Constants())
    @nospecialize model outputs constants
    steps >= 0 || throw(ArgumentError("steps must be nonnegative"))
    state_strategy in (:native, :references) || throw(ArgumentError("Unknown lean state strategy"))
    state_strategy === :native && !(model.status_storage isa PSE.NativeColumnStorage) &&
        throw(ArgumentError("Native lean execution requires canonical native storage from construction"))
    record = LeanCompilationRecord()
    compiler = performance ? PSE.compile_model_execution_plan : LeanPlanCompiler(state_strategy, record)
    simulation = PSE.run!(model; steps=0, constants, outputs, performance,
        _execution_plan_compiler=compiler)
    _reports[simulation] = record
    if performance
        record.logical_status_views = length(simulation.compiled.status_views_by_target)
        record.constructed_rich_targets = sum((length(batch.targets) for batch in simulation.execution_plan.batches); init=0)
        push!(record.reasons, (application=:all, targets=record.constructed_rich_targets,
            reason=:performance_instrumentation))
    end
    steps == 0 || PSE.continue!(simulation; steps)
    return simulation
end

function lean_report(simulation::PSE.Simulation)
    record = get(_reports, simulation, nothing)
    isnothing(record) && throw(ArgumentError("Simulation was not prepared by prepare_lean"))
    sum_counter(name) = sum((getfield(counter, name) for counter in record.counters); init=0)
    live_batches = count(batch -> batch isa Driver.LeanNumericalBatch, simulation.execution_plan.batches)
    ordinary_live_targets = sum((batch isa Driver.LeanNumericalBatch ? 0 : length(batch.targets)
        for batch in simulation.execution_plan.batches); init=0)
    return (driver_batch_executions=sum_counter(:driver_batches),
        driver_row_executions=sum_counter(:driver_rows), native_row_executions=sum_counter(:native_rows),
        executed_native_column_fields=sum_counter(:native_fields),
        publication_rows=sum_counter(:publication_rows), lean_batches_prepared=record.lean_batches,
        live_lean_batches=live_batches, skipped_rich_targets=record.skipped_rich_targets,
        constructed_rich_targets=record.constructed_rich_targets,
        lazy_target_snapshots=record.lazy_target_snapshots, ordinary_live_targets,
        logical_status_views_retained=record.logical_status_views,
        lean_contexts_prepared=record.contexts,
        refresh_fell_back_to_ordinary=record.lean_batches > 0 && live_batches == 0,
        logical_compiler_preserved=true, initial_eligible_rich_rows_retained=false,
        generated_outer_stack=false, numerical_scalar_copies=false,
        fallback_policy=:ordinary_on_unsupported_application_or_any_runtime_refresh,
        reasons=copy(record.reasons))
end

# Preserve the readable generated-source execution API for a caller that loads
# only this entry point. It uses lazy ordinary snapshots when explicitly asked;
# native preparation and normal continuation still construct none eagerly.
include(joinpath(@__DIR__, "lean_inspection.jl"))

end # module
