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
