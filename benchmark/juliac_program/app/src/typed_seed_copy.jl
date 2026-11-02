module TypedSeedCopies

export prepare, copy_seed, copy_payload, schema, payload_schema

"""Closed field and mutable-family schemas, derived only during authoring."""
struct CopySchema{M,F} end
struct CopyPlan{S,T}
    schema::S
    seed::T
end
schema(plan::CopyPlan)=plan.schema

_atomic(::Type{T}) where {T}=isbitstype(T) || T<:Union{Symbol,AbstractString,Type,Module}
_union(types)=isempty(types) ? Union{} : Union{types...}

"""Prepare an acyclic owned graph for typed copies preserving mutable aliases.

Actual concrete field families close abstract authoring storage. Array sizes,
dictionary keys, identities and numerical values remain runtime data. Cycles
and opaque storage are rejected before a native image is built. Undefined
array slots retain their original storage semantics.
"""
function prepare(seed;extra_types=())
    fields=Dict{DataType,Vector{Set{Type}}}()
    containers=Dict{DataType,Vector{Set{Type}}}()
    mutables=Set{DataType}()
    visited=IdDict{Any,Nothing}()
    active=IdDict{Any,Nothing}()
    function inspect(value)
        T=typeof(value)
        _atomic(T) && return
        if ismutabletype(T)
            haskey(active,value) && throw(ArgumentError("typed seed copies require an acyclic graph"))
            haskey(visited,value) && return
            active[value]=nothing
            push!(mutables,T)
        end
        if T===BigInt
            get!(fields,T,Set{Type}[])
        elseif value isa Array
            entry=get!(containers,T,[Set{Type}()])
            isconcretetype(eltype(T)) && push!(entry[1],eltype(T))
            for index in eachindex(value)
                isassigned(value,index) || continue
                item=value[index]
                push!(entry[1],typeof(item));inspect(item)
            end
        elseif value isa Union{Dict,IdDict}
            entry=get!(containers,T,[Set{Type}(),Set{Type}()])
            K,V=keytype(T),valtype(T)
            isconcretetype(K) && push!(entry[1],K)
            isconcretetype(V) && push!(entry[2],V)
            for (key,item) in value
                push!(entry[1],typeof(key));push!(entry[2],typeof(item))
                inspect(key);inspect(item)
            end
        else
            isstructtype(T) && !(T<:BigFloat) || throw(ArgumentError("opaque seed storage requires an explicit owned copier: $T"))
            entry=get!(fields,T,[Set{Type}() for _ in 1:fieldcount(T)])
            for index in 1:fieldcount(T)
                isdefined(value,index) || throw(ArgumentError("undefined struct field in typed seed"))
                item=getfield(value,index)
                push!(entry[index],typeof(item));inspect(item)
            end
        end
        if ismutabletype(T)
            delete!(active,value);visited[value]=nothing
        end
        return
    end
    inspect(seed)
    # Empty concrete containers and future declared payloads still need their
    # element/field schemas, even when the initial graph has no such values.
    expanding=Set{DataType}()
    function inspect_type(T)
        T isa Union && return foreach(inspect_type,Base.uniontypes(T))
        T isa DataType && isconcretetype(T) || throw(ArgumentError("unclosed seed payload family $T"))
        _atomic(T) && return
        T in expanding && return
        push!(expanding,T)
        ismutabletype(T) && push!(mutables,T)
        if T===BigInt
            get!(fields,T,Set{Type}[])
        elseif T<:Array
            entry=get!(containers,T,[Set{Type}()])
            if isempty(entry[1])
                isconcretetype(eltype(T)) || throw(ArgumentError("empty abstract array payload requires a concrete schema"))
                push!(entry[1],eltype(T))
            end
            foreach(inspect_type,entry[1])
        elseif T<:Union{Dict,IdDict}
            entry=get!(containers,T,[Set{Type}(),Set{Type}()])
            for (index,type) in enumerate((keytype(T),valtype(T)))
                if isempty(entry[index])
                    isconcretetype(type) || throw(ArgumentError("empty abstract dictionary payload requires a concrete schema"))
                    push!(entry[index],type)
                end
                foreach(inspect_type,entry[index])
            end
        else
            isstructtype(T) && !(T<:BigFloat) || throw(ArgumentError("opaque seed storage requires an explicit owned copier: $T"))
            entry=get!(fields,T,[Set{Type}() for _ in 1:fieldcount(T)])
            for index in eachindex(entry)
                isempty(entry[index]) && push!(entry[index],fieldtype(T,index))
                foreach(inspect_type,entry[index])
            end
        end
        return
    end
    foreach(inspect_type,collect(keys(fields)))
    foreach(inspect_type,collect(keys(containers)))
    foreach(inspect_type,extra_types)
    mutable_types=sort!(collect(mutables);by=string)
    entries=Type[]
    for T in sort!(collect(keys(fields));by=string)
        push!(entries,Tuple{T,Tuple{map(_union,fields[T])...}})
    end
    for T in sort!(collect(keys(containers));by=string)
        push!(entries,Tuple{T,Tuple{map(_union,containers[T])...}})
    end
    S=CopySchema{Tuple{mutable_types...},Tuple{entries...}}
    return CopyPlan(S(),seed)
end

@generated function _memo(::CopySchema{M,F}) where {M,F}
    return Expr(:tuple,[:(IdDict{$T,$T}()) for T in fieldtypes(M)]...)
end

function _field_schema(::Type{F},::Type{T}) where {F,T}
    index=findfirst(entry->fieldtype(entry,1)===T,fieldtypes(F))
    isnothing(index) && error("payload $T was not admitted by the copy schema")
    return fieldtype(fieldtype(F,index),2)
end

@generated function _copy(value::T,memo,plan::CopySchema{M,F}) where {T,M,F}
    _atomic(T) && return :(value)
    slots=fieldtypes(M)
    index=ismutabletype(T) ? findfirst(==(T),slots) : nothing
    ismutabletype(T) && isnothing(index) && return :(throw(ArgumentError("unadmitted mutable seed family")))
    fields=_field_schema(F,T)
    if T===BigInt
        body=quote
            copied=Base.GMP.MPZ.set(value)
            table[value]=copied
        end
    elseif T<:Array
        E=fieldtype(fields,1)
        body=quote
            copied=similar(value)
            table[value]=copied
            for row in eachindex(value)
                isassigned(value,row) || continue
                copied[row]=_copy(value[row]::$E,memo,plan)
            end
        end
    elseif T<:Union{Dict,IdDict}
        K,V=fieldtypes(fields)
        body=quote
            copied=$T()
            table[value]=copied
            for (key,item) in value
                copied[_copy(key::$K,memo,plan)]=_copy(item::$V,memo,plan)
            end
        end
    else
        values=[:(_copy(getfield(value,$i)::$(fieldtype(fields,i)),memo,plan)) for i in 1:fieldcount(T)]
        # :new reconstructs the exact admitted storage, including const fields
        # and inner-constructor types. Its values already satisfy field types.
        construction=Expr(:new,T,values...)
        body=ismutabletype(T) ? quote
            copied=$construction
            table[value]=copied
        end : :(return $construction)
    end
    if ismutabletype(T)
        return quote
            table=getfield(memo,$index)
            haskey(table,value) && return table[value]
            $body
            copied::$T
        end
    end
    return body
end

copy_seed(plan::CopyPlan)=_copy(plan.seed,_memo(plan.schema),plan.schema)

function _subset_schema(::Type{M},::Type{F},types) where {M,F}
    reached=Set{Type}()
    function visit(type)
        type isa Union && return foreach(visit,Base.uniontypes(type))
        _atomic(type) && return
        type in reached && return
        push!(reached,type)
        foreach(visit,fieldtypes(_field_schema(F,type)))
    end
    foreach(visit,types)
    mutable_types=Tuple(type for type in fieldtypes(M) if type in reached)
    entries=Tuple(entry for entry in fieldtypes(F) if fieldtype(entry,1) in reached)
    return CopySchema{Tuple{mutable_types...},Tuple{entries...}}
end

"""Authoring projection retaining only the supplied payload families."""
payload_schema(::CopySchema{M,F},types::Tuple) where {M,F}=_subset_schema(M,F,types)()
payload_schema(plan::CopyPlan,types::Tuple)=payload_schema(plan.schema,types)

@generated function _payload_schema(::Type{T},::CopySchema{M,F}) where {T,M,F}
    S=_subset_schema(M,F,(T,))
    return :($S())
end

"""Snapshot one payload using only its reachable mutable-family memo tables."""
function copy_payload(value::T,plan::CopySchema) where {T}
    _atomic(T) && return value
    subset=_payload_schema(T,plan)
    return _copy(value,_memo(subset),subset)
end
copy_payload(value,plan::CopyPlan)=copy_payload(value,plan.schema)

end
