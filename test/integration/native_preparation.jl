module NativePreparation
import PlantSimEngine as PSE
export close_registry, RuntimeTypes, InputTrace, remember!, batch_schema

function close_registry(model)
    previous = model.registry
    manifest = PSE._scenario_preparation(model).status_manifest
    for object in PSE.model_objects(model)
        status = PSE.model_status(model, object)
        (status === nothing || typeof(status) === manifest.status_type) ||
            error("Fresh objects lost the prepared canonical Status owner.")
        status === object.status || error("The facade lost its canonical status.")
    end
    store = PSE._closed_object_family_store(previous.objects)
    store.catalog.status_manifest === manifest || error("Registry closure changed the manifest.")
    registry = PSE.ObjectRegistry(store, previous.by_scale, previous.by_kind,
        previous.by_species, previous.ancestor_ids_by_object)
    # Build-time reconstruction retains every field of this exact model.
    return PSE.CompositeModel(registry,
        (getfield(model, index) for index in 2:fieldcount(typeof(model)))...)
end

mutable struct RuntimeTypes
    inputs::Vector{DataType}
    views::Dict{Symbol,Vector{DataType}}
end
RuntimeTypes() = RuntimeTypes(DataType[], Dict{Symbol,Vector{DataType}}())
remember!(pool, T) = (T in pool || push!(pool, T); nothing)
struct InputTrace <: AbstractVector{PSE.CompiledModelInputBinding}
    data::Vector{PSE.CompiledModelInputBinding}
    observed::RuntimeTypes
end
InputTrace(observed) = InputTrace(PSE.CompiledModelInputBinding[], observed)
Base.IndexStyle(::Type{InputTrace}) = IndexLinear()
Base.size(values::InputTrace) = size(values.data)
Base.getindex(values::InputTrace, index::Int) = values.data[index]
function Base.setindex!(values::InputTrace, binding, index::Int)
    remember!(values.observed.inputs, typeof(binding)); values.data[index] = binding; return values
end
function Base.push!(values::InputTrace, binding)
    remember!(values.observed.inputs, typeof(binding)); push!(values.data, binding); return values
end
function Base.insert!(values::InputTrace, index::Integer, binding)
    remember!(values.observed.inputs, typeof(binding)); insert!(values.data, index, binding); return values
end
Base.append!(values::InputTrace, bindings) = (foreach(binding -> push!(values, binding), bindings); values)
Base.similar(values::InputTrace, n::Integer) =
    InputTrace(Vector{PSE.CompiledModelInputBinding}(undef, n), values.observed)
function Base.similar(values::InputTrace, ::Type{T}, dims::Dims{1}) where {T}
    T === PSE.CompiledModelInputBinding || error("Preserve the input trace element contract.")
    return similar(values, only(dims))
end
Base.copy(values::InputTrace) = InputTrace(copy(values.data), values.observed)
Base.empty!(values::InputTrace) = (empty!(values.data); values)
Base.resize!(values::InputTrace, n::Integer) = (resize!(values.data, n); values)
Base.sizehint!(values::InputTrace, n::Integer) = (sizehint!(values.data, n); values)
Base.deleteat!(values::InputTrace, indices) = (deleteat!(values.data, indices); values)
PSE._construct_model_status_view(::RuntimeTypes, application::Symbol, parts) =
    PSE._construct_model_status_view(nothing, application, parts)
function PSE._admit_model_status_view!(observed::RuntimeTypes, application::Symbol, view)
    remember!(get!(Vector{DataType}, observed.views, application), typeof(view)); return view
end
function PSE._with_model_status_view(f::F, ::RuntimeTypes, application::Symbol,
    view, args::Vararg{Any,N}) where {F,N}
    return f(view, args...)
end
function PSE._with_temporal_copy_payloads(f::F, ::RuntimeTypes, binding, status,
    args::Vararg{Any,N}) where {F,N}
    return f(nothing, binding, status, args...)
end


function batch_schema(types)
    isempty(types) && error("Missing actual finite-owner batch evidence.")
    all(B -> isconcretetype(B) && B <: PSE.CompiledExecutionBatch,types) || error("Not real batch types.")
    return PSE.PreparedExecutionBatchSchema{Vector{Union{types...}}}()
end

end # module
