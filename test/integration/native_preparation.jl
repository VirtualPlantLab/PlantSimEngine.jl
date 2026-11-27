module NativePreparation
import PlantSimEngine as PSE
export close_registry, RuntimeTypes, InputTrace, remember!, batch_schema

function close_registry(model, id_type=nothing)
    manifest = PSE._scenario_preparation(model).status_manifest
    for object in PSE.model_objects(model)
        status = PSE.model_status(model, object)
        (status === nothing || typeof(status) === manifest.status_type) ||
            error("Fresh objects lost the prepared canonical Status owner.")
        status === object.status || error("The facade lost its canonical status.")
    end
    prepared = PSE._with_object_id_domain(model, id_type)
    prepared.registry.objects.catalog.status_manifest === manifest ||
        error("Registry closure changed the manifest.")
    return prepared
end

mutable struct RuntimeTypes
    inputs::Set{Tuple{Int,DataType}}
    views::Dict{Symbol,Vector{DataType}}
end
RuntimeTypes() = RuntimeTypes(Set{Tuple{Int,DataType}}(), Dict{Symbol,Vector{DataType}}())
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
    push!(values.observed.inputs, (binding.slot, typeof(binding)))
    values.data[index] = binding
    return values
end
function Base.push!(values::InputTrace, binding)
    push!(values.observed.inputs, (binding.slot, typeof(binding)))
    push!(values.data, binding)
    return values
end
function Base.insert!(values::InputTrace, index::Integer, binding)
    push!(values.observed.inputs, (binding.slot, typeof(binding)))
    insert!(values.data, index, binding)
    return values
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

# Each trajectory starts on a fresh scene. The returned program starts at step
# zero and admits the input, view and batch types seen along those trajectories.
function prepare_growth_fixture(make_model, ids, trajectories)
    ignore(sim) = nothing
    for advance! in trajectories
        advance!(PSE.run!(make_model(); steps=0, outputs=:all), ignore)
    end

    observed = RuntimeTypes()
    trace = InputTrace(observed)
    collecting = PSE._collecting_environment_binding_schema()
    function prepare(environment_schema, input_binding_storage, status_view_schema)
        return PSE._prepare_simulation!(close_registry(make_model()); steps=0, outputs=:all,
            constants=PSE.Constants(), environment_schema, input_binding_storage, status_view_schema)
    end
    slot_counts = map(trajectories) do advance!
        simulation = prepare(collecting, trace, observed)
        advance!(simulation, ignore)
        length(simulation.compiled.scenario_plan.input_plans)
    end
    isempty(trace) || error("Input prototype was mutated.")
    inputs = PSE._prepared_input_bindings(only(unique(slot_counts)), observed.inputs)
    views = PSE.CompiledMetadataTable(NamedTuple{ids}(map(ids) do id
        types = observed.views[id]
        all(T -> isconcretetype(T) && T <: PSE.CompiledModelStatusView, types) ||
            error("Expected concrete status views for application $id.")
        Vector{Union{types...}}()
    end))
    environment = PSE._freeze_environment_binding_schema(collecting)
    fresh() = prepare(environment, inputs, views)
    batches = Dict(id => DataType[] for id in ids)
    function observe(sim)
        sim.compiled.input_bindings.family_by_slot === inputs.family_by_slot || error("Lost input slot admissions.")
        sim.compiled.status_view_schema === views || error("Lost finite view owner.")
        for group in sim.execution_plan.groups, batch in group.batches
            remember!(batches[batch.application.id], typeof(batch))
        end
    end
    for advance! in trajectories
        advance!(fresh(), observe)
    end
    schemas = NamedTuple{ids}(map(id -> batch_schema(batches[id]), ids))
    return PSE._prepare_execution_batch_schemas(fresh(), schemas)
end

end # module
