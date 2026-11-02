isdefined(@__MODULE__, :OrdinaryObservations) || include(joinpath(@__DIR__, "observations.jl"))
module OrdinaryObservationChecks
using Test, SHA, Serialization
import ..OrdinaryObservations as O
function digest(value)
    io=IOBuffer();serialize(io,O.canonical(value));bytes2hex(sha256(take!(io)))
end
@testset "value fingerprints exclude storage padding and retain scientific bits" begin
    samples=[(1.0,true),(2.0,false)]
    T=eltype(samples)
    @test isbitstype(T)
    @test sizeof(T)>sum(sizeof,fieldtypes(T))
    @test digest(samples)==digest(copy(samples))
    @test digest(samples)==digest([(1.0,true),(2.0,false)])
    @test !isbitstype(eltype(O.canonical(samples).values))
    @test digest([0.0])!=digest([-0.0])
    @test digest([1f0])!=digest([1.0])
    @test digest([1,2,3,4])!=digest(reshape([1,2,3,4],2,2))
    @test digest(Float32[])!=digest(Float64[])
    @test digest(fill(1.0))!=digest([1.0])
    nan_a=reinterpret(Float64,UInt64(0x7ff8000000000001))
    nan_b=reinterpret(Float64,UInt64(0x7ff8000000000002))
    @test isequal(nan_a,nan_b)
    @test digest([nan_a])!=digest([nan_b])
    source=[1.0,2.0]
    saved=digest(source)
    source[1]=3.0
    @test digest(source)!=saved
    @test digest(view(source,1:1))!=digest(source)
    @test digest((id=:a,value=1.0))!=digest((id=:b,value=1.0))
end
end
