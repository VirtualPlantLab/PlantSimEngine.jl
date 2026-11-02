# Included in the host check namespace and the standalone native entry module.
# Same tags as the frozen benchmark's value_bytes!, with statically projected
# struct fields; no show/Serialization/Any fallback in the compiled entry.
_emit(io,::Nothing)=write(io,UInt8(0))
_emit(io,x::Bool)=write(io,UInt8(1),UInt8(x))
_emit(io,x::Unsigned)=write(io,UInt8(2),UInt8(sizeof(x)),UInt64(x))
_emit(io,x::Signed)=write(io,UInt8(3),UInt8(sizeof(x)),Int64(x))
_emit(io,x::AbstractFloat)=write(io,UInt8(4),UInt8(sizeof(x)),Float64(x))
function _emit(io,x::Enum)
    write(io,UInt8(11),Int64(Int(x)));_emit(io,nameof(typeof(x)));nothing
end
function _emit(io,x::Union{Symbol,AbstractString})
    text=string(x);write(io,UInt8(x isa Symbol ? 5 : 6),UInt64(ncodeunits(text)));write(io,codeunits(text));nothing
end
function _emit(io,x::AbstractArray)
    write(io,UInt8(8),UInt64(ndims(x)))
    for d in size(x);write(io,UInt64(d));end
    for item in x;_emit(io,item);end
    nothing
end
_emit_tuple(io,::Tuple{})=nothing
function _emit_tuple(io,x::Tuple)
    _emit(io,first(x));_emit_tuple(io,Base.tail(x));nothing
end
function _emit(io,x::Tuple)
    write(io,UInt8(9),UInt64(length(x)));_emit_tuple(io,x);nothing
end
@generated function _emit(io,x::T) where T
    fields=fieldnames(T)
    calls=[:(_emit(io,$(QuoteNode(name)));_emit(io,getfield(x,$i))) for (i,name) in enumerate(fields)]
    return quote
        write(io,UInt8(10),UInt64($(length(fields))))
        _emit(io,$(QuoteNode(nameof(T))))
        $(calls...)
        nothing
    end
end
@generated function _emit_native(io,plant::T) where T
    calls=[:(_emit(io,$(QuoteNode(name)));_emit(io,getfield(plant,$i)))
        for (i,name) in enumerate(fieldnames(T)) if name!==:parameters]
    return quote $(calls...);nothing end
end
_sample_key(sample)=(sample.id.value,sample.step)
function emit_state(io,state)
    _emit(io,(:amap_registry_snapshot_v1,state.step,state.retain,length(state.program.plant_ids),length(state.organ_lookup)))
    _emit(io,(state.program.architecture_name,state.program.publisher_names,state.program.length_name,state.program.count_name))
    _emit(io,state.program.scene_id.value)
    _emit(io,state.program.scene_children)
    for row in eachindex(state.program.plant_ids)
        status=state.plant_statuses[row]
        _emit(io,(state.program.plant_ids[row].value,status.development_increment,status.native_revision,state.plant_children[row]))
        _emit_native(io,status._native_pse_state.native.plant)
    end
    for row in state.committed_rows
        status=state.organ_statuses[row]
        _emit(io,(state.organ_ids[row].value,state.organ_parents[row].value,state.organ_geometry[row],
            status.length,status.observed_length,status.qualification_runs))
    end
    _emit(io,sort!(copy(state.architecture_samples);by=_sample_key))
    for stream in state.publisher_samples;_emit(io,sort!(copy(stream);by=_sample_key));end
    _emit(io,sort!(copy(state.length_samples);by=_sample_key))
    _emit(io,sort!(copy(state.count_samples);by=_sample_key))
    return nothing
end
