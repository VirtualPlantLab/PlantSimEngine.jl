struct ExistingStatusReference{I} end
struct EditedStatusReference{I} end

"""Ordered reference selections for a status schema, without object state or defaults."""
struct StatusConstructionRecipe{Names,A<:Tuple}
    actions::A
end

function StatusConstructionRecipe(existing_names::Tuple, edit_names::Tuple)
    names = collect(Symbol, existing_names)
    actions = Any[ExistingStatusReference{index}() for index in eachindex(names)]
    for (index, name) in pairs(edit_names)
        position = findfirst(isequal(name), names)
        action = EditedStatusReference{index}()
        if isnothing(position)
            push!(names, name)
            push!(actions, action)
        else
            actions[position] = action
        end
    end
    selections = Tuple(actions)
    return StatusConstructionRecipe{Tuple(names),typeof(selections)}(selections)
end

@inline _status_construction_reference(::ExistingStatusReference{I}, existing, edited) where {I} =
    getfield(existing, I)
@inline _status_construction_reference(::EditedStatusReference{I}, existing, edited) where {I} =
    getfield(edited, I)

function _construct_status(
    recipe::StatusConstructionRecipe{Names},
    existing::Tuple,
    edited::Tuple,
) where {Names}
    references = map(recipe.actions) do action
        _status_construction_reference(action, existing, edited)
    end
    return Status(NamedTuple{Names}(references))
end

function _status_construction_recipe!(cache, existing_names::Tuple, edit_names::Tuple)
    return get!(cache, (existing_names, edit_names)) do
        StatusConstructionRecipe(existing_names, edit_names)
    end
end

"""An exact reference layout using the canonical StatusConstructionRecipe."""
struct ExactReferenceFactory{Existing,Edited,Result,R}
    construction::R

    ExactReferenceFactory{Existing,Edited,Result,R}(construction::R) where {Existing,Edited,Result,R} =
        new{Existing,Edited,Result,R}(construction)
end

_status_schema_names(::Type{Nothing}) = ()
_status_schema_names(::Type{Status{Names,Refs}}) where {Names,Refs} = Names
_status_schema_references(::Type{Status{Names,Refs}}) where {Names,Refs} = Refs
_status_schema_values(::Nothing) = ()
_status_schema_values(status::Status) = refvalues(status)

_selected_status_reference_type(::ExistingStatusReference{I}, existing, edited) where {I} =
    fieldtype(existing, I)
_selected_status_reference_type(::EditedStatusReference{I}, existing, edited) where {I} =
    fieldtype(edited, I)

# Host/schema-time operation: names and exact reference types only, no values,
# defaults, callback calls or fake Status objects.
function ExactReferenceFactory(::Type{Existing}, ::Type{Edited}, ::Type{Result}, edit_names::Tuple) where {Existing,Edited<:Tuple,Result<:Status}
    (Existing === Nothing || Existing <: Status) && isconcretetype(Existing) &&
        isconcretetype(Edited) && isconcretetype(Result) ||
        throw(ArgumentError("An exact reference factory requires concrete status/reference schemas."))
    fieldcount(Edited) == length(edit_names) && all(T -> T <: Ref, fieldtypes(Edited)) ||
        throw(ArgumentError("Edited reference types do not match their declared field names."))
    original_refs = Existing === Nothing ? Tuple{} : _status_schema_references(Existing)
    construction = StatusConstructionRecipe(_status_schema_names(Existing), edit_names)
    selected_types = map(construction.actions) do action
        _selected_status_reference_type(action, original_refs, Edited)
    end
    _status_schema_names(Result) == typeof(construction).parameters[1] &&
        Tuple{selected_types...} === _status_schema_references(Result) ||
        throw(ArgumentError("Reference selections do not produce the admitted status schema."))
    return ExactReferenceFactory{Existing,Edited,Result,typeof(construction)}(construction)
end

@inline function _construct_status(factory::ExactReferenceFactory{Existing,Edited,Result}, original::Existing, edited::Edited) where {Existing,Edited,Result}
    return _construct_status(factory.construction, _status_schema_values(original), edited)::Result
end
