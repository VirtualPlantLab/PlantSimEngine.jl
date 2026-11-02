function _samples(simulation,application,variable,::Type{I},::Type{T}) where {I,T}
    result=OP.Sample{I,T}[]
    for ((app,id,var),stream) in pairs(PSE.outputs(simulation))
        app===application && var===variable || continue
        for sample in stream
            push!(result,OP.Sample(id::I,Int(first(sample)),last(sample)::T))
        end
    end
    return sort!(result;by=_sample_key)
end
function emit_ordinary(io,simulation,fixture,cfg)
    plants=[PSE.model_object(fixture.model,id) for id in fixture.plant_ids]
    organs=sort!(PSE.model_objects(fixture.model;scale=:IN);by=object->object.id.value)
    scene=PSE.model_object(fixture.model,:scene)
    _emit(io,(:amap_registry_snapshot_v1,PSE.current_step(simulation),cfg.outputs===:all,length(plants),length(organs)))
    _emit(io,(:native_architecture,Symbol[Symbol("native_properties_",i,"_Internode") for i in eachindex(plants)],:length_probe,:qualification_count))
    _emit(io,scene.id.value);_emit(io,scene.children)
    for object in plants
        status=object.status
        _emit(io,(object.id.value,status.development_increment,status.native_revision,object.children))
        _emit_native(io,status._native_pse_state.native.plant)
    end
    for object in organs
        status=object.status
        _emit(io,(object.id.value,object.parent.value,PSE.geometry(object),status.length,status.observed_length,status.qualification_runs))
    end
    _emit(io,_samples(simulation,:native_architecture,:native_revision,OP.PlantId,Int))
    for i in eachindex(plants)
        _emit(io,_samples(simulation,Symbol("native_properties_",i,"_Internode"),:length,OP.OrganId,Float32))
    end
    _emit(io,_samples(simulation,:length_probe,:observed_length,OP.OrganId,Float32))
    _emit(io,_samples(simulation,:qualification_count,:qualification_runs,OP.OrganId,Int))
    nothing
end
