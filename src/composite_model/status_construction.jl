struct ExistingStatusReference{I} end
struct EditedStatusReference{I} end

"""Ordered reference selections for a status schema, without object state or defaults."""
struct StatusConstructionRecipe{Names,A<:Tuple}
    actions::A
end

@inline _status_construction_reference(::ExistingStatusReference{I}, existing, edited) where {I} =
    getfield(existing, I)
@inline _status_construction_reference(::EditedStatusReference{I}, existing, edited) where {I} =
    getfield(edited, I)

"""An exact reference layout using the canonical StatusConstructionRecipe."""
struct ExactReferenceFactory{Existing,Edited,Result,R}
    construction::R

    ExactReferenceFactory{Existing,Edited,Result,R}(construction::R) where {Existing,Edited,Result,R} =
        new{Existing,Edited,Result,R}(construction)
end

_status_schema_names(::Type{Nothing}) = ()
_status_schema_names(::Type{Status{Names,T}}) where {Names,T} = Names
_status_schema_references(::Type{Status{Names,T}}) where {Names,T} =
    _status_storage_reference_types(T)

# These witnesses contain only the prepared namespace and exact reference
# classes, so identical views share one schema calculation across objects.
@generated function _projected_status_type(
    ::Type{C}, ::Val{NAMES}, ::Type{R},
) where {C<:Status,NAMES,R<:Tuple}
    return QuoteNode(_projected_status_type(C, NAMES, R))
end

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
    storage = fieldtype(Result, :vars)
    projected = storage <: _ProjectedStatusStorage
    wanted = projected ? fieldnames(fieldtype(storage, :hot)) : _status_schema_names(Result)
    original_names = _status_schema_names(Existing)
    original_refs = Existing === Nothing ? Tuple{} : _status_schema_references(Existing)
    actions = map(wanted) do name
        edited = findlast(isequal(name), edit_names)
        isnothing(edited) || return EditedStatusReference{edited}()
        original = findfirst(isequal(name), original_names)
        isnothing(original) && throw(ArgumentError("A requested kernel reference has no source."))
        ExistingStatusReference{original}()
    end
    selected = map(action -> _selected_status_reference_type(action, original_refs, Edited), actions)
    expected = projected ? fieldtype(storage, :hot).parameters[2] : _status_schema_references(Result)
    all(index -> fieldtype(expected,index) <: selected[index], eachindex(selected)) ||
        throw(ArgumentError("Reference selections are outside the admitted status schema."))
    construction = StatusConstructionRecipe{wanted,typeof(actions)}(actions)
    return ExactReferenceFactory{Existing,Edited,Result,typeof(construction)}(construction)
end

@generated function _construct_status(factory::ExactReferenceFactory{Existing,Edited,Result}, original::Existing, edited::Edited) where {Existing,Edited,Result}
    Storage = fieldtype(Result, :vars)
    projected = Storage <: _ProjectedStatusStorage
    Names = projected ? fieldnames(fieldtype(Storage, :hot)) : _status_schema_names(Result)
    Refs = projected ? fieldtype(Storage, :hot).parameters[2] : _status_schema_references(Result)
    # Read the reference layout once. Each action indexes this named tuple
    # directly, including when a field is present only in the full snapshot.
    load_refs = Existing === Nothing ? :(NamedTuple()) : :(_initial_status_reference_storage(original))
    hot = [:( _status_construction_reference(getfield(factory.construction.actions,$i),
        original_refs, edited)::$(fieldtype(Refs,i)) ) for i in eachindex(Names)]
    Hot = NamedTuple{Names,Refs}
    dense = :($Hot($(Expr(:tuple,hot...))))
    projected || return quote
        original_refs = $load_refs
        return Status($dense)::Result
    end
    FullNames = _status_schema_names(Result)
    Full = fieldtype(Storage, :refs)
    full = map(eachindex(FullNames)) do i
        name = FullNames[i]
        hot_index = findfirst(isequal(name), Names)
        reference = isnothing(hot_index) ? :(get(original_refs,$(QuoteNode(name)),nothing)) :
                    :(getfield(hot,$hot_index))
        :($reference::$(fieldtype(Full,i)))
    end
    return quote
        original_refs = $load_refs
        hot = $dense
        snapshot = $Full($(Expr(:tuple,full...)))
        return Status($Storage(hot, snapshot, _status_reference_epoch(original)))::Result
    end
end
