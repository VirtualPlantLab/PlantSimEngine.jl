module CachedDeclarationProofs

using PlantSimEngine
const PSE=PlantSimEngine
const PT=Main.PersistentTightProgram
export DeclarationProofCache, prove!, pure_declaration!, declaration_proof_report,
    lower_cached_proofs!, prepare_cached_proofs

"""Bounded, explicitly shared admission proofs. No model or declaration values.

The entire table expires when Julia's method world changes. This deliberately
trades conservative invalidation for a small, auditable correctness boundary.
Both accepted and declined type/effect proofs are retained. The lock covers
compiler queries as well as insertion, so simultaneous fresh preparations do
not run the same query twice in a stable world.
"""
mutable struct DeclarationProofCache
    entries::Dict{Tuple{Any,Any,UInt},Bool}
    mutex::ReentrantLock
    capacity::Int
    world::UInt
    hits::Int
    positive_hits::Int
    negative_hits::Int
    misses::Int
    effects_queries::Int
    return_type_queries::Int
    world_invalidations::Int
    capacity_resets::Int
    invalidated_entries::Int
    world_race_retries::Int
end
function DeclarationProofCache(;capacity::Integer=2048)
    capacity>0 || throw(ArgumentError("Proof cache capacity must be positive"))
    return DeclarationProofCache(Dict{Tuple{Any,Any,UInt},Bool}(),ReentrantLock(),
        Int(capacity),UInt(0),0,0,0,0,0,0,0,0,0,0)
end

function _observe_world!(cache,world)
    if cache.world!=world
        if cache.world!=0
            cache.world_invalidations+=1
            cache.invalidated_entries+=length(cache.entries)
        end
        empty!(cache.entries)
        cache.world=world
    end
    return nothing
end

"""Prove the original persistent admission predicate without calling `f`.

Only singleton functions and type arguments enter the table. The benchmark's
declarations are named generic functions, so this guard excludes closures
carrying scientific state without narrowing those supported declarations.
Compiler results are checked in the same way as the original executor: the
effects must be unconditionally consistent, effect-free and nonthrowing, and
the inferred return must be a concrete `NamedTuple` type.
"""
Base.@nospecializeinfer @noinline function prove!(cache::DeclarationProofCache,f,T)
    @nospecialize f T
    f isa Function && Base.issingletontype(typeof(f)) ||
        throw(ArgumentError("Declaration proof keys require a singleton function"))
    T isa Type || throw(ArgumentError("Declaration proof keys require an argument type"))
    lock(cache.mutex)
    try
        while true
            world=Base.get_world_counter()
            _observe_world!(cache,world)
            key=(f,T,world)
            if haskey(cache.entries,key)
                proof=cache.entries[key]
                if Base.get_world_counter()!=world
                    cache.world_race_retries+=1
                    continue
                end
                cache.hits+=1
                proof ? (cache.positive_hits+=1) : (cache.negative_hits+=1)
                return proof
            end
            cache.misses+=1
            cache.effects_queries+=1
            effects=Base.infer_effects(f,Tuple{T};world)
            cache.return_type_queries+=1
            inferred=Base.promote_op(f,T)
            always=getfield(parentmodule(typeof(effects)),:ALWAYS_TRUE)
            proof=effects.consistent==always && effects.effect_free==always &&
                effects.nothrow && inferred isa DataType && inferred<:NamedTuple &&
                isconcretetype(inferred)
            if Base.get_world_counter()!=world
                cache.world_race_retries+=1
                continue
            end
            if length(cache.entries)>=cache.capacity
                cache.capacity_resets+=1
                cache.invalidated_entries+=length(cache.entries)
                empty!(cache.entries)
            end
            cache.entries[key]=proof
            return proof
        end
    finally
        unlock(cache.mutex)
    end
end
pure_declaration!(cache::DeclarationProofCache,f,T)=prove!(cache,f,T)

function declaration_proof_report(cache::DeclarationProofCache)
    lock(cache.mutex)
    try
        return (;policy=:strict_type_effect_proofs_per_function_type_world,
            world=cache.world,current_world=Base.get_world_counter(),
            entries=length(cache.entries),capacity=cache.capacity,
            hits=cache.hits,positive_hits=cache.positive_hits,negative_hits=cache.negative_hits,
            misses=cache.misses,effects_queries=cache.effects_queries,
            return_type_queries=cache.return_type_queries,
            compiler_queries=cache.effects_queries+cache.return_type_queries,
            world_invalidations=cache.world_invalidations,capacity_resets=cache.capacity_resets,
            invalidated_entries=cache.invalidated_entries,world_race_retries=cache.world_race_retries,
            live_declaration_calls=0,stores_scientific_values=false)
    finally
        unlock(cache.mutex)
    end
end

# Dispatch is selected by an explicit field on this preparation's record.
# Ordinary and persistent controls retain the original per-record proof path.
PT._pure_declaration!(cache::DeclarationProofCache,record,f,T)=prove!(cache,f,T)

function lower_cached_proofs!(simulation::PSE.Simulation;
    cache::DeclarationProofCache,count_calls::Bool=false,kwargs...)
    return PT.lower_persistent_tight!(simulation;count_calls,declaration_policy=cache,kwargs...)
end
function prepare_cached_proofs(model::PSE.CompositeModel;
    cache::DeclarationProofCache,kwargs...)
    return PT.prepare_persistent_tight(model;declaration_policy=cache,kwargs...)
end

end # module
