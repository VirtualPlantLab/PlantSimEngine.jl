module TypedOutputPreparation

using PlantSimEngine
const PSE = PlantSimEngine
isdefined(PSE, :_try_prepare_output_status_application!) ||
    error("Typed output preparation requires its optional per-application hook")

export enable_typed_output_preparation!, typed_output_preparation_report

mutable struct PreparationCounters
    application_attempts::Int
    applications_completed::Int
    objects_prepared::Int
    canonical_ports_visited::Int
    defaults_added::Int
    initial_applications_completed::Int
    initial_objects_prepared::Int
    growth_applications_completed::Int
    growth_objects_prepared::Int
    declines::Int
end
PreparationCounters() = PreparationCounters(0,0,0,0,0,0,0,0,0,0)
mutable struct PreparationState
    counts::PreparationCounters
    decline_reasons::Dict{Symbol,Int}
end
PreparationState() = PreparationState(PreparationCounters(), Dict{Symbol,Int}())
const _enabled = WeakKeyDict{Any,PreparationState}()

"""Specialize one batched output-status loop on its individual ModelSpec type.

Enable before initial preparation. The application metadata is extracted once
and dispatched to one typed helper. Current defaults, target-vector iteration,
canonical routing, conversion callbacks and status recipes use the original
functions in the original order. Nothing is cached across invocations. This
changes neither scientific model code nor status/plan representations.
"""
function enable_typed_output_preparation!(model::PSE.CompositeModel)
    haskey(_enabled, model) && return model
    isnothing(model.binding_cache) || throw(ArgumentError(
        "Enable typed output preparation before initial logical compilation"))
    _enabled[model] = PreparationState()
    return model
end

function _decline!(state, reason)
    state.counts.declines += 1
    state.decline_reasons[reason] = get(state.decline_reasons, reason, 0) + 1
    return false
end

function _fixed_field(record_type, name)
    return hasfield(record_type, name) &&
        (!ismutabletype(record_type) || isconst(record_type, name))
end

# The only specialization dimension here is the single application's concrete
# ModelSpec S. The scene, recipes and conversion-record dictionary stay erased;
# a whole scenario model tuple is never part of this helper's inferred payload.
Base.@nospecializeinfer @noinline function _prepare_application!(
    spec::S, application_id::Symbol, target_ids::Vector{PSE.ObjectId},
    model, recipes, recipe_order, conversion_records, state::PreparationState,
) where {S<:PSE.ModelSpec}
    @nospecialize model recipes recipe_order conversion_records
    initial = model.binding_cache === nothing
    # Preserve this call even for targetless applications and effectful or
    # parameter-dependent declarations; no schema/default certificate is used.
    defaults = PSE._local_output_schema(spec)
    objects = ports = added = 0
    for object_id in target_ids
        preparation = PSE._status_preparation_for_object!(
            recipes, recipe_order, model, object_id)
        for (variable, value) in pairs(defaults)
            PSE._publish_mode_for_output(spec, variable) == :canonical || continue
            ports += 1
            if preparation isa PSE.Status
                variable in propertynames(preparation) && continue
                preparation = PSE._status_recipe_for_object!(
                    recipes, recipe_order, model, object_id)
            end
            changed = PSE._status_recipe_add_default!(model, preparation,
                object_id, variable, value; application_id,
                origin=:model_output_default, conversion_records)
            added += changed === true
        end
        objects += 1
    end
    # Only completed invocations are credited. An exception propagates without
    # replaying any application or rolling back ordinary metadata side effects.
    counts = state.counts
    counts.applications_completed += 1
    counts.objects_prepared += objects
    counts.canonical_ports_visited += ports
    counts.defaults_added += added
    if initial
        counts.initial_applications_completed += 1
        counts.initial_objects_prepared += objects
    else
        counts.growth_applications_completed += 1
        counts.growth_objects_prepared += objects
    end
    return true
end

Base.@nospecializeinfer @noinline function PSE._try_prepare_output_status_application!(
    model::PSE.CompositeModel, application::PSE.CompiledModelApplication,
    recipes, recipe_order, conversion_records,
)
    @nospecialize model application recipes recipe_order conversion_records
    state = get(_enabled, model, nothing)
    state === nothing && return false
    state.counts.application_attempts += 1
    plan = getfield(application, :plan)
    plan_type = typeof(plan)
    _fixed_field(plan_type, :spec) && _fixed_field(plan_type, :id) ||
        return _decline!(state, :mutable_or_unknown_plan_fields)
    isdefined(plan, :spec) && isdefined(plan, :id) ||
        return _decline!(state, :undefined_plan_fields)
    spec = getfield(plan, :spec)
    id = getfield(plan, :id)
    spec isa PSE.ModelSpec && id isa Symbol || return _decline!(state, :nonstandard_spec_or_id)
    return _prepare_application!(spec, id, getfield(application, :target_ids),
        model, recipes, recipe_order, conversion_records, state)
end

Base.@nospecializeinfer @noinline function typed_output_preparation_report(value)
    @nospecialize value
    model = value isa PSE.Simulation ? value.model : value
    model isa PSE.CompositeModel || throw(ArgumentError("Expected CompositeModel or Simulation"))
    state = get(_enabled, model, nothing)
    fields = fieldnames(PreparationCounters)
    counters = NamedTuple{fields}(Tuple(state === nothing ? 0 : getfield(state.counts, field)
        for field in fields))
    return (enabled=state !== nothing, counters,
        decline_reasons=state === nothing ? Dict{Symbol,Int}() : copy(state.decline_reasons),
        specialization_scope=:individual_application_ModelSpec_only_scene_and_records_erased,
        completion_scope=:completed_application_body_and_actual_object_port_visits,
        growth_definition=:after_initial_binding_cache_publication_not_unique_newborn_objects,
        default_evaluation=:fresh_once_per_application_in_original_order_including_targetless,
        cached_defaults=false, cached_memberships=false, copied_scientific_values=false,
        status_storage=:original_canonical_references_and_status_recipes)
end

end # module
