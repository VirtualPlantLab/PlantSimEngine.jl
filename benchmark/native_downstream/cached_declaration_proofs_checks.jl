module CachedDeclarationProofChecks

using Dates, Test, PlantSimEngine
const PSE=PlantSimEngine
const CP=Main.CachedDeclarationProofs
const PT=Main.PersistentTightProgram
export cached_proof_checks, cached_proof_world_checks, cached_proof_admission_checks

struct ProofParameters{T}
    initial::T
end
struct WorldProofParameters
    initial::Float64
end
const _declaration_side_effects=Ref(0)
_parameter_value(model::ProofParameters)=(value=model.initial,)
_different_function(model::ProofParameters)=(value=model.initial,)
function _side_effect_value(model::ProofParameters)
    _declaration_side_effects[]+=1
    return (value=model.initial,)
end
_throwing_value(model::ProofParameters)=error("must never evaluate this declaration")
_non_namedtuple(model::ProofParameters)=model.initial
_world_value(model::WorldProofParameters)=(value=model.initial,)

"""No model is evaluated; compiler-only positive/negative and concurrency checks."""
function cached_proof_checks()
    cache=CP.DeclarationProofCache(;capacity=8)
    _declaration_side_effects[]=0
    @testset "Explicit bounded declaration proof cache" begin
        @test CP.prove!(cache,_parameter_value,ProofParameters{Float64})
        first=CP.declaration_proof_report(cache)
        @test first.misses==1 && first.compiler_queries==2 && first.hits==0
        # The only inputs to the cache are type and function. Different model
        # instances and values have no representation in its table.
        left,right=ProofParameters(1.25),ProofParameters(907.5)
        @test left.initial!=right.initial && typeof(left)===typeof(right)
        @test CP.prove!(cache,_parameter_value,typeof(right))
        same_type=CP.declaration_proof_report(cache)
        @test same_type.hits==1 && same_type.misses==1
        @test CP.prove!(cache,_parameter_value,ProofParameters{Float32})
        @test CP.prove!(cache,_different_function,ProofParameters{Float64})
        distinct=CP.declaration_proof_report(cache)
        @test distinct.misses==3 && distinct.compiler_queries==6
        @test !CP.prove!(cache,_side_effect_value,ProofParameters{Float64})
        negative=CP.declaration_proof_report(cache)
        @test !CP.prove!(cache,_side_effect_value,ProofParameters{Float64})
        negative_hit=CP.declaration_proof_report(cache)
        @test negative_hit.misses==negative.misses
        @test negative_hit.negative_hits==1
        @test !CP.prove!(cache,_throwing_value,ProofParameters{Float64})
        @test !CP.prove!(cache,_non_namedtuple,ProofParameters{Float64})
        @test _declaration_side_effects[]==0
        @test all(value isa Bool for value in values(cache.entries))
        @test all(key[1] isa Function && key[2] isa Type && key[3] isa UInt for key in keys(cache.entries))
        @test all(!(item isa ProofParameters) for key in keys(cache.entries) for item in key)
        @test CP.declaration_proof_report(cache).live_declaration_calls==0
        @test_throws ArgumentError CP.DeclarationProofCache(;capacity=0)
        @test_throws ArgumentError CP.prove!(cache,_parameter_value,left)

        bounded=CP.DeclarationProofCache(;capacity=2)
        for T in (Float64,Float32,Int)
            @test CP.prove!(bounded,_parameter_value,ProofParameters{T})
        end
        limited=CP.declaration_proof_report(bounded)
        @test limited.entries==1 && limited.capacity_resets==1
        @test limited.invalidated_entries==2

        concurrent=CP.DeclarationProofCache()
        tasks=map(1:8) do _
            Threads.@spawn CP.prove!(concurrent,_parameter_value,ProofParameters{Float64})
        end
        @test all(fetch,tasks)
        shared=CP.declaration_proof_report(concurrent)
        @test shared.misses==1 && shared.hits==7 && shared.compiler_queries==2
    end
    return CP.declaration_proof_report(cache)
end

"""Method replacement invalidates a formerly positive proof, then a negative one.

Run before benchmark warmup: these deliberate method definitions advance the
Julia world, and a cache must never conceal their effect from admission.
"""
function cached_proof_world_checks()
    cache=CP.DeclarationProofCache()
    _declaration_side_effects[]=0
    Core.eval(@__MODULE__, :(_world_value(model::WorldProofParameters)=(value=model.initial,)))
    @testset "Declaration proofs follow method world changes" begin
        @test Base.invokelatest(CP.prove!,cache,_world_value,WorldProofParameters)
        before=CP.declaration_proof_report(cache)
        Core.eval(@__MODULE__, quote
            function _world_value(model::WorldProofParameters)
                _declaration_side_effects[]+=1
                return (value=model.initial,)
            end
        end)
        @test !Base.invokelatest(CP.prove!,cache,_world_value,WorldProofParameters)
        changed=CP.declaration_proof_report(cache)
        @test changed.world!=before.world && changed.world_invalidations==1
        @test changed.misses==2 && changed.entries==1
        @test changed.invalidated_entries==1
        @test _declaration_side_effects[]==0
        @test !Base.invokelatest(CP.prove!,cache,_world_value,WorldProofParameters)
        @test CP.declaration_proof_report(cache).negative_hits==1
        Core.eval(@__MODULE__, :(_unrelated_world_marker()=nothing))
        @test !Base.invokelatest(CP.prove!,cache,_world_value,WorldProofParameters)
        unrelated=CP.declaration_proof_report(cache)
        @test unrelated.world_invalidations==2 && unrelated.misses==3
        @test _declaration_side_effects[]==0
    end
    return CP.declaration_proof_report(cache)
end

PSE.@process "cached_proof_unknown" verbose=false
struct UnknownProofModel <: AbstractCached_Proof_UnknownModel end
PSE.inputs_(::UnknownProofModel)=NamedTuple()
PSE.outputs_(::UnknownProofModel)=(x=0.0,)
PSE.run!(::UnknownProofModel,status,environment,constants,context)=(status.x+=1;nothing)
function _unknown_fixture()
    return PSE.CompositeModel(PSE.Object(:unit);
        applications=(PSE.ModelSpec(UnknownProofModel();name=:unknown,
            on=PSE.One(id=:unit),every=Hour(1)),),environment=(duration=Hour(1),))
end

"""An unsupported kernel never runs even a declaration compiler query."""
function cached_proof_admission_checks()
    cache=CP.DeclarationProofCache()
    @testset "Unknown capabilities remain ordinary before proof queries" begin
        control=PSE.run!(_unknown_fixture();steps=0,outputs=:all)
        candidate=PSE.run!(_unknown_fixture();steps=0,outputs=:all)
        CP.lower_cached_proofs!(candidate;cache,count_calls=true)
        @test CP.declaration_proof_report(cache).compiler_queries==0
        @test PT.persistent_tight_report(candidate).live_regions==0
        @test PT.persistent_tight_report(candidate).batch_executions==0
        PSE.step!(control)
        PSE.step!(candidate)
        @test isequal(PSE.final_state(control),PSE.final_state(candidate))
        @test isequal(PSE.collect_outputs(control),PSE.collect_outputs(candidate))
        @test CP.declaration_proof_report(cache).compiler_queries==0
    end
    return (;proofs=CP.declaration_proof_report(cache),execution=:ordinary)
end

end # module
