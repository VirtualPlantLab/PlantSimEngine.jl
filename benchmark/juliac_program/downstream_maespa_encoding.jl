module DownstreamMAESPAEncoding

export encode, encode_record

# Text tags are derived from closed Julia schemas while authoring/compiling.
# The runtime never asks generic display to inspect scientific payloads.
@generated _type_tag(::Type{T}) where {T}=QuoteNode(string(T))
function _prefix(io,value)
    print(io,_type_tag(typeof(value)),':')
    return nothing
end
function encode(io,value::Union{Bool,Integer,AbstractFloat,Symbol,AbstractString})
    _prefix(io,value)
    if value isa AbstractString
        print(io,ncodeunits(value),':',value)
    else
        print(io,value)
    end
    return nothing
end
encode(io,::Nothing)=print(io,"Nothing:null")
encode(io,::Missing)=print(io,"Missing:missing")
function encode(io,value::AbstractArray)
    _prefix(io,value)
    print(io,'[')
    for dimension in size(value)
        print(io,dimension,',')
    end
    print(io,"|")
    for element in value
        encode(io,element); print(io,';')
    end
    print(io,']')
    return nothing
end
@generated function encode(io,value::T) where {T}
    isconcretetype(T) || return :(throw(ArgumentError("scientific output schema must be concrete")))
    fields=[:(begin
        print(io,$(QuoteNode(string(name))), '=')
        encode(io,getfield(value,$index)); print(io,';')
    end) for (index,name) in enumerate(fieldnames(T))]
    return quote
        _prefix(io,value); print(io,'{')
        $(fields...)
        print(io,'}')
        nothing
    end
end
@generated function encode_record(io,fields::T) where {T<:Tuple}
    calls=[:(begin encode(io,getfield(fields,$index)); print(io,'|') end) for index in 1:fieldcount(T)]
    return Expr(:block,calls...,:(println(io)),:(nothing))
end

end
