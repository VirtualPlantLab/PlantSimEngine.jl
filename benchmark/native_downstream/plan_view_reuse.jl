module PlanViewReuse

using PlantSimEngine
const PSE = PlantSimEngine

for name in (:_prepare_compiled_model_status_view, :_prepare_preserved_model_status_view)
    isdefined(PSE, name) || error("This prototype requires the preparation-reuse hooks from its investigation branch")
end

export enable_plan_view_reuse!, disable_plan_view_reuse!, prepare_reuse,
    plan_view_reuse_report

"""Object-independent metadata only. No model, Status, Ref, default or sample."""
struct PlainViewRecipe
    signature::Tuple
    many_slots::Tuple
    many_names::Tuple
end

mutable struct ReuseRecord
    enabled::Bool
    recipes::Bool
    views::Bool
    plans::Dict{Symbol,PlainViewRecipe}
    recipe_builds::Int
    recipe_hits::Int
    recipe_view_assemblies::Int
    ordinary_compiler_calls::Int
    plain_preservations::Int
    ordinary_preservations::Int
    bound_interface_reuses::Int
    fallback_reasons::Dict{Symbol,Int}
end
ReuseRecord(recipes, views) = ReuseRecord(true, recipes, views,
    Dict{Symbol,PlainViewRecipe}(), 0, 0, 0, 0, 0, 0, 0, Dict{Symbol,Int}())

# Values contain counters and symbolic assembly metadata only; they cannot
# retain a scientific model through a key -> cache -> model cycle.
const _records = WeakKeyDict{Any,ReuseRecord}()

function enable_plan_view_reuse!(model::PSE.CompositeModel; recipes::Bool=true, views::Bool=true)
    _records[model] = ReuseRecord(recipes, views)
    return model
end
function disable_plan_view_reuse!(model::PSE.CompositeModel)
    record = get(_records, model, nothing)
    isnothing(record) || (record.enabled = false)
    return model
end
function _fallback!(record, reason)
    record.fallback_reasons[reason] = get(record.fallback_reasons, reason, 0) + 1
    return nothing
end

function _build_recipe(bindings)
    signature = Any[]
    many_slots = Int[]
    many_names = Symbol[]
    for (index, binding) in pairs(bindings)
        binding.carrier_hint === :temporal_stream && return nothing
        name, multiplicity = binding.input, binding.multiplicity
        push!(signature, (name, multiplicity, binding.carrier_hint))
        if multiplicity === :many
            name in many_names && return nothing
            push!(many_slots, index)
            push!(many_names, name)
        end
    end
    return PlainViewRecipe(Tuple(signature), Tuple(many_slots), Tuple(many_names))
end

function _recipe_matches(recipe, bindings)
    length(recipe.signature) == length(bindings) || return false
    for (index, binding) in pairs(bindings)
        name, multiplicity, hint = recipe.signature[index]
        binding.input === name && binding.multiplicity === multiplicity &&
            binding.carrier_hint === hint || return false
    end
    return true
end

Base.@nospecializeinfer @noinline function _assemble_plain_view(recipe, canonical_status, bindings)
    @nospecialize canonical_status bindings
    isempty(recipe.many_slots) && return PSE.CompiledModelStatusView(
        canonical_status, canonical_status, (), NamedTuple(), NamedTuple())
    values = Any[]
    for slot in recipe.many_slots
        binding = bindings[slot]
        carrier = getproperty(canonical_status, binding.input)
        # Preserve the original non-vector error, validation and live identity
        # contract; schemas never stand in for current mutable carrier values.
        carrier isa AbstractVector || error(
            "Compiled Many input `$(binding.input)` has non-vector runtime value `$(typeof(carrier))`.")
        push!(values, PSE._compiled_bound_many(binding.source_ids, carrier))
    end
    bound_inputs = NamedTuple{recipe.many_names}(Tuple(values))
    return PSE.CompiledModelStatusView(canonical_status, canonical_status,
        (), NamedTuple(), bound_inputs)
end

Base.@nospecializeinfer @noinline function PSE._prepare_compiled_model_status_view(
    model::PSE.CompositeModel, application::PSE.CompiledModelApplication,
    object_id::PSE.ObjectId, bindings, applications_by_id, positions, distributed_outputs,
)
    @nospecialize model application bindings applications_by_id positions distributed_outputs
    record = get(_records, model, nothing)
    if isnothing(record) || !record.enabled
        return PSE._compile_model_status_view(model, application, object_id,
            bindings, applications_by_id, positions, distributed_outputs)
    end
    if record.recipes && isempty(PSE.output_routing(application.spec))
        recipe = get(record.plans, application.id, nothing)
        if isnothing(recipe) || !_recipe_matches(recipe, bindings)
            !isnothing(recipe) && _fallback!(record, :binding_shape_changed)
            recipe = _build_recipe(bindings)
            if !isnothing(recipe)
                record.plans[application.id] = recipe
                record.recipe_builds += 1
            end
        else
            record.recipe_hits += 1
        end
        if !isnothing(recipe)
            # Every object gets its current, complete canonical status. No
            # immutable schema cache stores row state or shares output cells.
            canonical = PSE._ensure_model_object_status!(model, object_id)
            view = _assemble_plain_view(recipe, canonical, bindings)
            record.recipe_view_assemblies += 1
            return view
        end
        _fallback!(record, :temporal_or_duplicate_many_boundary)
    else
        _fallback!(record, record.recipes ? :output_routing_boundary : :recipes_disabled)
    end
    record.ordinary_compiler_calls += 1
    return PSE._compile_model_status_view(model, application, object_id,
        bindings, applications_by_id, positions, distributed_outputs)
end

function _canonical_plain_view(view)
    isempty(view.temporal_inputs) && isempty(view.private_outputs) || return false
    status, canonical = view.status, view.canonical_status
    status isa PSE.Status && canonical isa PSE.Status || return false
    # _status_vars follows a backing; a projected canonical status may also
    # override a field locally. Keep that unusual boundary in ordinary code.
    getfield(canonical, :backing) === nothing || return false
    if status !== canonical
        names = propertynames(canonical)
        propertynames(status) == names || return false
        for name in names
            PSE.refvalue(status, name) === PSE.refvalue(canonical, name) || return false
        end
    end
    for name in propertynames(view.bound_inputs)
        bound = getproperty(view.bound_inputs, name)
        carrier = getproperty(canonical, name)
        bound.values === carrier || return false
        ids = bound.ids.ids
        length(ids) == length(carrier) && axes(ids) == axes(carrier) || return false
        Base.require_one_based_indexing(ids, carrier)
    end
    return true
end

Base.@nospecializeinfer @noinline function PSE._prepare_preserved_model_status_view(
    model::PSE.CompositeModel, current::PSE.CompiledModelStatusView,
    previous::PSE.CompiledModelStatusView, previous_temporal_sources, key,
)
    @nospecialize model current previous previous_temporal_sources key
    record = get(_records, model, nothing)
    if !isnothing(record) && record.enabled
        if record.views && _canonical_plain_view(current) &&
            isempty(previous.temporal_inputs) && isempty(previous.private_outputs)
            # Ordinary preservation ALWAYS creates a fresh Status identity,
            # including its plain branch. Keep that observable behavior while
            # reusing the already assembled immutable reference tuple and the
            # egal-equivalent BoundMany interface metadata.
            canonical = current.canonical_status
            status = PSE.Status(PSE._status_vars(canonical))
            result = PSE.CompiledModelStatusView(status, canonical, (),
                NamedTuple(), current.bound_inputs)
            record.plain_preservations += 1
            record.bound_interface_reuses += length(current.bound_inputs)
            return result
        end
        record.ordinary_preservations += 1
        _fallback!(record, record.views ? :temporal_private_or_noncanonical_view : :view_reuse_disabled)
    end
    return PSE._preserve_model_status_view_temporal_state!(
        current, previous, previous_temporal_sources, key)
end

function prepare_reuse(model::PSE.CompositeModel; steps::Integer=0, outputs=:none,
    performance::Bool=false, constants=PSE.PlantMeteo.Constants(), recipes::Bool=true,
    views::Bool=true, kwargs...)
    enable_plan_view_reuse!(model; recipes, views)
    return PSE.run!(model; steps, outputs, performance, constants, kwargs...)
end

function plan_view_reuse_report(model::PSE.CompositeModel)
    record = get(_records, model, nothing)
    isnothing(record) && return (enabled=false, recipe_builds=0, recipe_hits=0,
        recipe_view_assemblies=0, ordinary_compiler_calls=0, plain_preservations=0,
        ordinary_preservations=0, bound_interface_reuses=0, recipe_entries=0,
        fallback_reasons=Dict{Symbol,Int}())
    return (enabled=record.enabled, recipes=record.recipes, views=record.views,
        recipe_builds=record.recipe_builds, recipe_hits=record.recipe_hits,
        recipe_view_assemblies=record.recipe_view_assemblies,
        ordinary_compiler_calls=record.ordinary_compiler_calls,
        plain_preservations=record.plain_preservations,
        ordinary_preservations=record.ordinary_preservations,
        bound_interface_reuses=record.bound_interface_reuses,
        recipe_entries=length(record.plans), fallback_reasons=copy(record.fallback_reasons),
        cached_scientific_values=false, cached_status_references=false,
        cached_environment_samples=false, affected_view_identity=:fresh_as_ordinary,
        reuse=:symbolic_plain_view_recipes_and_current_bound_interfaces)
end
plan_view_reuse_report(simulation::PSE.Simulation) = plan_view_reuse_report(simulation.model)

end # module
