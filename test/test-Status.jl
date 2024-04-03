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

@testset "Testing ModelList Status" begin
    # Create a ModelList
    models = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        status=(var1=[15.0, 16.0], var2=0.3)
    )

    @test typeof(status(models)) == TimeStepTable{
        Status{
            (:var5, :var4, :var6, :var1, :var3, :var2),
            NTuple{6,Base.RefValue{Float64}}
        }
    }
    @test status(models) == models.status
    @test status(models)[1] == status(models, 1)

    @test typeof(status(models, 1)) == PlantMeteo.TimeStepRow{
        Status{
            (:var5, :var4, :var6, :var1, :var3, :var2),
            NTuple{6,Base.RefValue{Float64}}
        }
    }

    @test status(models, 1).var1 == 15.0
    @test status(models, 1).var2 == 0.3
    @test status(models).var1 == [15.0, 16.0]
    @test status(models).var2 == [0.3, 0.3]

    @test status(models, :var4) == [-Inf, -Inf]
    @test status(models, 1).var3 == -Inf
    @test status(models, 1).var4 == -Inf
    @test status(models, 1).var5 == -Inf
    @test status(models, 1).var6 == -Inf

    # Testing setindex:
    models[:var6] = [5.5, 5.8]
    @test status(models, :var6) == [5.5, 5.8]

    # Testing a vector of ModelList:
    @test status([models, models]) == [models.status, models.status]
    # Testing a Dict of ModelList:
    @test status(Dict(:m1 => models, :m2 => models)) == Dict(:m1 => models.status, :m2 => models.status)
end