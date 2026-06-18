# This tests comes from https://github.com/MasonProtter/MutableNamedTuples.jl/blob/master/test/runtests.jl
@testset "Testing Status" begin
    mnt = Status(a=1, b="hi")
    @test mnt isa Status
    @test mnt.a == 1
    @test NamedTuple(mnt) == (; a=1, b="hi")
    @test collect(mnt) == [1; "hi"]
    @test length(mnt) == 2
    @test mnt[1] == 1
    @test mnt[2] == "hi"
    @test mnt[:a] == 1
    @test mnt[:b] == "hi"

    mnt2 = Status{(:a, :b)}((1, "hi"))
    @test NamedTuple(mnt2) == NamedTuple(mnt)
    @test NamedTuple(mnt2) == (; a=1, b="hi")
    @test Tuple(mnt2) == (1, "hi")
    @test keys(mnt2) == (:a, :b)
    @test values(mnt2) == (1, "hi")

    # Testing setproperty:
    mnt2.a = 3
    @test mnt2.a == 3

    # Testing setindex!:
    mnt2[1] = 4
    @test mnt2.a == 4

    mnt2[:b] = "hello"
    @test mnt2.b == "hello"
end
