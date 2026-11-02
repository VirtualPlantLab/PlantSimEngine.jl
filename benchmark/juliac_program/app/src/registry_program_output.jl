# Included inside RegistryPrograms. Encoding is shared with the ordinary-PSE
# observation driver, and is outside every measured simulation interval.
include(joinpath(@__DIR__,"..","..","downstream_maespa_encoding.jl"))
const RegistryEncoding=DownstreamMAESPAEncoding

@generated function _print_registry_status(io,id,status::PSE.Status{N}) where {N}
    records=[:(RegistryEncoding.encode_record(io,("S",id,$(QuoteNode(name)),getfield(getfield(status,:vars),$index)[])))
        for (index,name) in enumerate(N)]
    return Expr(:block,records...,:(nothing))
end
function _print_registry_object(io,object)
    metadata=object.metadata
    RegistryEncoding.encode_record(io,("T",object.id,metadata.parent,
        metadata.children,metadata.scale,metadata.kind,metadata.species,metadata.geometry))
    _print_registry_status(io,object.id,object.status)
    return nothing
end
@generated function _print_registry_objects(io,groups::T) where {T<:Tuple}
    loops=[:(for object in getfield(groups,$index)
        _print_registry_object(io,object)
    end) for index in 1:fieldcount(T)]
    return Expr(:block,loops...,:(nothing))
end
function _print_registry_history(io,history)
    application,id,variable=history.key
    RegistryEncoding.encode_record(io,("H",application,id,variable))
    for (time,value) in history.samples
        RegistryEncoding.encode_record(io,("O",application,id,time,variable,value))
    end
    return nothing
end
@generated function _print_registry_histories(io,groups::T) where {T<:Tuple}
    loops=[:(for history in getfield(groups,$index)
        _print_registry_history(io,history)
    end) for index in 1:fieldcount(T)]
    return Expr(:block,loops...,:(nothing))
end
@generated function _registry_object_count(groups::T) where {T<:Tuple}
    return Expr(:call,:+,[:(length(getfield(groups,$index))) for index in 1:fieldcount(T)]...)
end

"""Print complete final canonical values, topology, streams and committed air.
Record order is intentionally irrelevant; comparison sorts complete records.
RNG ownership is qualified independently by the full host snapshot gate.
"""
function print_result(state::RegistryState,io=Core.stdout)
    RegistryEncoding.encode_record(io,("F",state.step,length(state.applications),_registry_object_count(state.objects)))
    _print_registry_objects(io,state.objects)
    _print_registry_histories(io,state.histories)
    binding=getfield(state.groups,1).targets[1].environment
    _print_registry_environment(io,binding)
    return nothing
end

function _print_registry_environment(io,binding::MAESPAEnvironmentBinding{B,H,P,A,R}) where {B,H,P,A,R}
    canopy=_committed_canopy(binding)
    if isnothing(canopy)
        RegistryEncoding.encode_record(io,("E",nothing))
    else
        RegistryEncoding.encode_record(io,("E",canopy::A))
    end
    return nothing
end
