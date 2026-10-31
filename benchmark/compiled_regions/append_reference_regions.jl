# Explicit pure-addition experiment. These stages borrow only newly resolved
# references; old rows, pointer vectors and installed batch owners stay live.
# Every rejection leaves the old region untouched for ordinary PSE rebuilding.

struct RegionReferenceAppend{B,I,R,M,O,F,K}
    batch::B
    object_ids::I
    reference_appends::R
    model_appends::M
    output_appends::O
    factory::F
    kernel::K
    targets_constructed::Int
end

struct RegionControlRefresh{F,C,FV,CV}
    factory::F
    context::C
    factory_values::FV
    context_values::CV
end
struct RegionGroupControlRefresh{S}
    stages::S
end

function _region_control_fields_accept(owner, values)
    return all(name -> getproperty(values, name) isa fieldtype(typeof(owner), name),
        keys(values))
end

if isdefined(PSE, :_stage_model_execution_group_control_refresh)
    function PSE._stage_model_execution_group_control_refresh(
        group::PSE.CompiledApplicationExecutionGroup{A,RegionBatchCollection},
        compiled, environment_bindings, temporal_streams, output_retention, constants,
    ) where {A}
        application = get(compiled.applications_by_id, group.application.id, nothing)
        isnothing(application) && return false
        application === group.application || return false
        stages = RegionControlRefresh[]
        for batch in group.batches
            batch isa RegionColumnBatch || continue
            factory = batch.targets.factory
            factory_values = (; compiled, environment_bindings, application,
                temporal_streams, output_retention, constants)
            _region_control_fields_accept(factory, factory_values) || return false
            context = batch.kernel.context
            context_values = context isa PSE.RunContext ?
                factory_values : NamedTuple()
            _region_control_fields_accept(context, context_values) || return false
            push!(stages, RegionControlRefresh(factory, context,
                factory_values, context_values))
        end
        return RegionGroupControlRefresh(stages)
    end

    function PSE._commit_model_execution_group_control_refresh!(stage::RegionGroupControlRefresh)
        for control in stage.stages
            for name in keys(control.factory_values)
                setfield!(control.factory, name, getproperty(control.factory_values, name))
            end
            for name in keys(control.context_values)
                setfield!(control.context, name, getproperty(control.context_values, name))
            end
        end
        return nothing
    end
end

function _region_current_environment_provider(environment, application, object_id)
    binding = PSE._environment_binding_for(environment, application.id, object_id)
    isnothing(binding) && return nothing
    binding.backend isa PSE.GlobalConstant || return PSE._UNSPECIFIED_SCENE_ENVIRONMENT
    return binding.uses_raw_global_source ?
        PSE.RawGlobalModelEnvironment(binding.prepared_source) :
        PSE.CachedGlobalModelEnvironment(binding)
end

function _region_append_existing_rows_match(batch, compiled, environment,
    application, temporal_streams, output_retention)
    names = keys(batch.state.data.references)
    for (row, object_id) in pairs(batch.targets.object_ids)
        model = PSE._application_model(application, object_id)
        model === GP._column_model_at(batch.kernel.models, row) || return false
        view = get(compiled.status_views_by_target, (application.id, object_id), nothing)
        isnothing(view) && return false
        current_names, current_writes, reason = _region_port_schema((; model, status=view.status))
        reason === :eligible && current_names == names &&
            current_writes == batch.state.written_names || return false
        isempty(PSE.environment_outputs_(model)) || return false
        isempty(view.temporal_inputs) || return false
        isempty(get(compiled.call_bindings_by_target,
            (application.id, object_id), ())) || return false
        isempty(PSE._runtime_model_output_targets(compiled, application, object_id)) ||
            return false
        for name in names
            name in keys(view.status) || return false
            PSE.refvalue(view.status, name) ===
                getproperty(batch.state.data.references, name)[row] || return false
        end
        PSE._model_execution_outputs_match(batch.kernel.output_bindings[row],
            compiled, application, object_id, output_retention, temporal_streams) ||
            return false
        isequal(_region_current_environment_provider(environment, application, object_id),
            batch.environment_provider) || return false
    end
    return true
end

if isdefined(PSE, :_stage_model_execution_group_pure_addition)
    function PSE._stage_model_execution_group_pure_addition(
        group::PSE.CompiledApplicationExecutionGroup{A,RegionBatchCollection},
        compiled, environment, application, temporal_streams, output_retention,
        constants, performance, object_ids, shared_plan_cache,
    ) where {A}
        length(group.batches) == 1 || return false
        batch = only(group.batches)
        batch isa RegionColumnBatch || return false
        state = batch.state
        state isa RegionReferenceState && state.appendable || return false
        isnothing(performance) || return false
        compiled.status_view_refresh_is_pure_addition || return false
        group.application === application || return false
        isempty(object_ids) && return false
        old_ids = batch.targets.object_ids
        all(object_id -> object_id isa eltype(old_ids), object_ids) || return false
        length(application.target_ids) == length(old_ids) + length(object_ids) || return false
        all(index -> application.target_ids[index] == old_ids[index], eachindex(old_ids)) ||
            return false
        all(index -> application.target_ids[length(old_ids) + index] == object_ids[index],
            eachindex(object_ids)) || return false
        PSE._object_id_isless(last(old_ids), first(object_ids)) || return false
        all(index -> PSE._object_id_isless(object_ids[index - 1], object_ids[index]),
            2:length(object_ids)) || return false
        # A pure-addition flag alone does not promise stable existing bindings.
        # Many/OptionalOne edits and mixed structural/environment events must
        # keep the ordinary refresh path whenever an existing port changes.
        _region_append_existing_rows_match(batch, compiled, environment,
            application, temporal_streams, output_retention) || return false
        isequal(PSE._compiled_output_publication(output_retention, application),
            batch.output_publication) || return false

        targets = [PSE._compiled_model_execution_target(compiled, environment,
            application, object_id, temporal_streams, output_retention, constants;
            shared_plan_cache) for object_id in object_ids]
        all(target -> typeof(target) === eltype(batch.targets), targets) || return false
        all(target -> typeof(target.context) === typeof(batch.kernel.context), targets) ||
            return false
        all(target -> isequal(PSE._compiled_model_execution_environment_provider(
            environment, application, target), batch.environment_provider), targets) ||
            return false
        staged_batch = PSE.CompiledExecutionBatch(application, targets,
            batch.environment_provider, batch.output_publication)
        names, writes, reason = _region_batch_reason((performance=nothing,), staged_batch)
        reason === :eligible || return false
        names == keys(state.data.references) && writes == state.written_names || return false

        reference_appends = IdDict{Any,Any}()
        for name in names
            previous = getproperty(state.data.references, name)
            references = [PSE.refvalue(target.status, name) for target in targets]
            all(reference -> typeof(reference) === eltype(previous), references) || return false
            # Previously shared whole-column pointer vectors cannot diverge
            # for new rows. Reject an alias split before touching either owner.
            if haskey(reference_appends, previous)
                staged = reference_appends[previous]
                all(index -> staged[index] === references[index], eachindex(references)) ||
                    return false
            else
                reference_appends[previous] = references
            end
        end
        models = batch.kernel.models
        model_appends = if models isa GP.SharedColumnModel
            all(target -> target.model === models.model, targets) || return false
            nothing
        else
            all(target -> typeof(target.model) === eltype(models.models), targets) || return false
            [target.model for target in targets]
        end
        output_appends = [target.output_bindings for target in targets]
        all(bindings -> typeof(bindings) === eltype(batch.kernel.output_bindings),
            output_appends) || return false
        factory = RegionTargetFactory(compiled, environment, application,
            temporal_streams, output_retention, constants)
        typeof(factory) === typeof(batch.targets.factory) || return false
        current = PSE._compiled_model_execution_target(compiled, environment,
            application, first(old_ids), temporal_streams, output_retention, constants;
            shared_plan_cache)
        typeof(current.context) === typeof(batch.kernel.context) || return false
        kernel = typeof(batch.kernel)(models, current.context,
            batch.environment_provider, batch.kernel.output_bindings)
        return RegionReferenceAppend(batch, copy(object_ids), reference_appends,
            model_appends, output_appends, factory, kernel, length(targets) + 1)
    end

    function PSE._commit_model_execution_group_pure_addition!(stage::RegionReferenceAppend)
        batch = stage.batch
        for (previous, references) in stage.reference_appends
            append!(previous, references)
        end
        isnothing(stage.model_appends) || append!(batch.kernel.models.models, stage.model_appends)
        append!(batch.kernel.output_bindings, stage.output_appends)
        append!(batch.targets.object_ids, stage.object_ids)
        batch.state.data.nrows = length(batch.targets.object_ids)
        batch.state.metadata_current = false
        factory = batch.targets.factory
        for field in fieldnames(typeof(factory))
            setfield!(factory, field, getfield(stage.factory, field))
        end
        batch.kernel = stage.kernel
        batch.counters.appended_batches += 1
        batch.counters.appended_rows += length(stage.object_ids)
        return nothing
    end
end
