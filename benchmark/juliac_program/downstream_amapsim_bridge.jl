# Included inside the frozen TYPED adapter fixture namespace only.
const OP = getproperty(parentmodule(@__MODULE__), :ObjectPrograms)
OP.model_role(::Adapter.NativeArchitecture) = :architecture
OP.model_role(::Adapter.NativePropertyPublisher) = :publisher
OP.model_role(::Bench.LengthProbe) = :length
OP.model_role(::QualificationCount) = :count
function OP.admit_native_state(state::Adapter.NativePSEState)
    state.plant_id isa PlantId || throw(ArgumentError("Symbol plant identity required"))
    state.growth_control === state.development === state.organ_growth === state.status_factory === nothing ||
        throw(ArgumentError("coupled callback protocols not admitted"))
    state.geometry && !state.coupled_pending && isempty(state.registered) ||
        throw(ArgumentError("prepare requires fresh native architecture with geometry"))
    state.growth_runtime[] === nothing || throw(ArgumentError("active growth runtime"))
    for group in state.groups
        group.mapping.symbol===:Internode && group.mapping.scale===:IN && group.mapping.kind===:internode &&
            isnothing(group.ids) && isempty(group.required) && Tuple(group.properties)==(:length=>:length,) ||
            throw(ArgumentError("only exact original internode projection admitted"))
    end
    return nothing
end
function OP.native_geometry_type(state::Adapter.NativePSEState)
    T=eltype(state.native.plant.organs)
    names=(:base,:tip,:frame,:length,:diameter_top,:diameter_bottom)
    return NamedTuple{names,Tuple{map(name->fieldtype(T,name),names)...}}
end
function OP.clone_native_state(state::Adapter.NativePSEState)
    return OP.clone_native_state(state,state.plant_id,state.native.plant.rng.seed)
end
function OP.clone_native_state(state::Adapter.NativePSEState,id::PlantId,seed::UInt64)
    plant=Native.NativeAMAPPlantEngine.initialize(state.native.plant.parameters,
        Native.NativeAMAPLegacyRNG.ObservedRNG(seed);compiled=true)
    native=Native.NativeModel(plant,state.native.geometry_parameters)
    return Adapter.NativePSEState(native,id,copy(state.product_symbols),copy(state.groups),
        empty(state.registered),state.geometry,nothing,nothing,Ref{Any}(nothing),nothing,nothing,false)
end
function Adapter._synchronize!(owner::OP.AbstractRegistryOwner,state::Adapter.NativePSEState)
    isempty(state.groups) && return nothing
    desired=Set{Tuple{Symbol,Int}}()
    for (slot,record) in enumerate(state.native.plant.organs)
        record.active && Adapter._product_symbol(state,record)===:Internode || continue
        key=(:Internode,slot);push!(desired,key)
        geometry=Adapter._geometry_snapshot(state,:Internode,record)::OP.native_geometry_type(state)
        if !haskey(state.registered,key)
            id=Adapter.native_object_id(state.plant_id,:Internode,slot)
            OP.register_record!(owner,OP.IN_GROUP;id,parent=state.plant_id,geometry,initial=(length=record.length,))
            state.registered[key]=id
        else
            id=state.registered[key]
            OP.record_parent(owner,id)==state.plant_id || OP.reparent_record!(owner,id,state.plant_id)
            isequal(OP.record_geometry(owner,id),geometry) || OP.update_geometry_record!(owner,id,geometry)
        end
    end
    stale=sort!([key for key in keys(state.registered) if !(key in desired)];by=last,rev=true)
    for key in stale
        OP.remove_record!(owner,state.registered[key]);delete!(state.registered,key)
    end
    return nothing
end

# Typed validation projection of the original adapter's identity contract.
# The error remains ArgumentError; formatting invalid IDs does not enter Base.show.
function Adapter._validate_projection_target(state::Adapter.NativePSEState,id::OrganId)
    plant,symbol,slot=id.value
    plant===state.plant_id.value && slot>0 &&
        get(state.registered,(symbol,slot),nothing)==id ||
        throw(ArgumentError("foreign object outside the registered native plant projection"))
    return nothing
end
