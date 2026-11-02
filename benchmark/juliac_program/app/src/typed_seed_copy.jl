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
Base.@nospecializeinfer function prepare(@nospecialize(seed);extra_types=())
    fields=Dict{DataType,Vector{Set{Type}}}()
    containers=Dict{DataType,Vector{Set{Type}}}()
    mutables=Set{DataType}()
    visited=IdDict{Any,Nothing}()
    active=IdDict{Any,Nothing}()
    Base.@nospecializeinfer function inspect(@nospecialize(value))
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
    Base.@nospecializeinfer function inspect_type(@nospecialize(T))
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
    tables=Expr[]
    for index in 1:fieldcount(M)
        T=fieldtype(M,index)
        push!(tables,:(IdDict{$T,$T}()))
    end
    return Expr(:tuple,tables...)
end

Base.@nospecializeinfer function _field_schema(@nospecialize(F::Type),@nospecialize(T::Type))
    for index in 1:fieldcount(F)
        entry=fieldtype(F,index)
        fieldtype(entry,1)===T && return fieldtype(entry,2)
    end
    error("payload family $(nameof(T)) was not admitted by the copy schema")
end

@generated function _copy(value::T,memo,plan::CopySchema{M,F}) where {T,M,F}
    _atomic(T) && return :(value)
    index=nothing
    if ismutabletype(T)
        for slot in 1:fieldcount(M)
            if fieldtype(M,slot)===T
                index=slot
                break
            end
        end
    end
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

Base.@nospecializeinfer function _subset_schema(@nospecialize(M::Type),@nospecialize(F::Type),@nospecialize(types))
    reached=Set{Type}()
    Base.@nospecializeinfer function visit(@nospecialize(type))
        type isa Union && return foreach(visit,Base.uniontypes(type))
        _atomic(type) && return
        type in reached && return
        push!(reached,type)
        fields=_field_schema(F,type)
        for index in 1:fieldcount(fields)
            visit(fieldtype(fields,index))
        end
    end
    foreach(visit,types)
    mutable_types=Type[]
    for index in 1:fieldcount(M)
        type=fieldtype(M,index)
        type in reached && push!(mutable_types,type)
    end
    entries=Type[]
    for index in 1:fieldcount(F)
        entry=fieldtype(F,index)
        fieldtype(entry,1) in reached && push!(entries,entry)
    end
    return CopySchema{Tuple{mutable_types...},Tuple{entries...}}
end

"""Authoring projection retaining only the supplied payload families."""
Base.@nospecializeinfer function payload_schema(@nospecialize(plan::CopySchema),@nospecialize(types::Tuple))
    M,F=typeof(plan).parameters
    return _subset_schema(M,F,types)()
end
Base.@nospecializeinfer payload_schema(@nospecialize(plan::CopyPlan),@nospecialize(types::Tuple))=payload_schema(plan.schema,types)

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
