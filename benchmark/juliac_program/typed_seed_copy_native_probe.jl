# Compile this standalone entry with JuliaC safe/generic through Kaimon.
module TypedSeedCopyNativeProbe
using Random
include(joinpath(@__DIR__,"app","src","typed_seed_copy.jl"))
const SEED=let values=[1.0,2.0],reference=nothing
 reference=Ref(values)
 (first=reference,second=reference,values=values,dict=Dict(:a=>reference,:b=>reference),
  paired=(reference,reference),rng=MersenneTwister(731),bits=BitVector([true,false]),
  slots=Vector{Vector{Float64}}(undef,2))
end
const PLAN=TypedSeedCopies.prepare(SEED)
const PAYLOAD_SCHEMA=TypedSeedCopies.payload_schema(PLAN,(typeof(SEED.paired),))
function main(args::Vector{String})
 copied=TypedSeedCopies.copy_seed(PLAN)
 copied.first===copied.second===copied.dict[:a]===copied.dict[:b] || return 2
 copied.values===copied.first[] || return 3
 copied.values!==SEED.values && copied.first!==SEED.first || return 4
 copied.values[1]=9.0
 SEED.values[1]==1.0 || return 5
 Random.rand(copied.rng,UInt64)==Random.rand(copy(SEED.rng),UInt64) || return 6
 payload=TypedSeedCopies.copy_payload(SEED.paired,PAYLOAD_SCHEMA)
 payload[1]===payload[2] && payload[1]!==SEED.first || return 7
 copied.bits==SEED.bits && copied.bits!==SEED.bits || return 8
 !isassigned(copied.slots,1) && !isassigned(copied.slots,2) || return 9
 println(Core.stdout,"COPY_OK")
 return 0
end
end

function (@main)(args::Vector{String})
    TypedSeedCopyNativeProbe.main(args)
end
