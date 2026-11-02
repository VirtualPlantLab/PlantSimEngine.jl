module TypedSeedCopyChecks

using Test, Random
include(joinpath(@__DIR__,"app","src","typed_seed_copy.jl"))
using .TypedSeedCopies

mutable struct OwnedBox
    const array::Vector{Int}
    scalar::Base.RefValue{Float64}
end
struct FuturePayload
    values::Vector{Float64}
end

function check()
    @testset "Closed seed copy ownership" begin
        shared=[1.0,2.0]
        reference=Ref(shared)
        slots=Vector{Vector{Float64}}(undef,4)
        slots[2]=shared
        seed=(first=reference,second=reference,paired=(reference,reference),shared=shared,
            dict=Dict(:a=>reference,:b=>reference),box=OwnedBox([3,4],Ref(5.0)),
            bits=BitVector([true,false]),rng=MersenneTwister(731),slots=slots,
            empty=FuturePayload[],name=:seed)
        plan=prepare(seed)
        copied=copy_seed(plan)
        @test copied.first===copied.second===copied.dict[:a]===copied.dict[:b]
        @test copied.first[]===copied.shared===copied.slots[2]
        @test copied.first!==seed.first
        @test copied.shared!==seed.shared
        @test copied.box!==seed.box
        @test copied.box.array!==seed.box.array
        @test copied.box.scalar!==seed.box.scalar
        @test copied.bits==seed.bits
        @test copied.bits!==seed.bits
        @test copied.name===:seed
        @test collect(keys(copied.dict))==collect(keys(seed.dict))
        @test isassigned.(Ref(copied.slots),1:4)==[false,true,false,false]
        @test rand(copy(copied.rng),UInt64,8)==rand(copy(seed.rng),UInt64,8)
        copied.shared[1]=99.0
        @test seed.shared[1]==1.0
        payload=copy_payload(seed.paired,plan)
        @test payload[1]===payload[2]
        @test payload[1]!==reference
        @test payload[1][]!==shared
        future=FuturePayload([4.0,5.0])
        snapshot=copy_payload(future,plan)
        @test snapshot.values==future.values
        @test snapshot.values!==future.values
        cyclic=Any[];push!(cyclic,cyclic)
        @test_throws ArgumentError prepare(cyclic)
        original_big=big(1)<<80
        copied_big=copy_seed(prepare(original_big))
        @test copied_big==original_big && copied_big!==original_big
        Base.GMP.MPZ.set_ui!(copied_big,7)
        @test original_big==big(1)<<80
        reduced=payload_schema(plan,(typeof(seed.paired),FuturePayload))
        @test fieldcount(typeof(reduced).parameters[2])<fieldcount(typeof(schema(plan)).parameters[2])
        @test copy_payload(future,reduced).values==future.values
        @test_throws ArgumentError prepare(big(1.0))
    end
    return (passed=true,scope=:aliases_private_payloads_rng_symbols_undefined_slots_and_admission)
end

end
