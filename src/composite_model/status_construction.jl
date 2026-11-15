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
_status_schema_values(::Nothing) = ()
_status_schema_values(status::Status{N,<:NamedTuple}) where {N} = refvalues(status)
_status_schema_values(status::Status{N,<:Union{_FixedStatusStorage,_ProjectedStatusStorage}}) where {N} =
    values(_status_snapshot_references(status))

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
    # Actions are metadata carried by the sole existing factory, not runtime types.
    hot = [:( _status_construction_reference(getfield(factory.construction.actions,$i),
        _status_schema_values(original), edited)::$(fieldtype(Refs,i)) ) for i in eachindex(Names)]
    Hot = NamedTuple{Names,Refs}
    projected || return :(Status($Hot($(Expr(:tuple,hot...))))::Result)
    FullNames = _status_schema_names(Result)
    Full = fieldtype(Storage, :refs)
    full = [begin
        index = findfirst(isequal(name), Names)
        isnothing(index) ? :(_initial_status_reference(original,$(QuoteNode(name)))::$(fieldtype(Full,i))) :
            :(getfield(hot,$index)::$(fieldtype(Full,i)))
    end for (i,name) in enumerate(FullNames)]
    return quote
        hot = $Hot($(Expr(:tuple,hot...)))
        snapshot = $Full($(Expr(:tuple,full...)))
        return Status($Storage(hot, snapshot, _status_reference_epoch(original)))::Result
    end
end
