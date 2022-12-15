# include("../examples/dummy.jl")

# Tests:
# Defining a list of models without status:
@testset "ModelList with no status" begin
    leaf = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model()
    )

    inits = merge(init_variables(leaf.models)...)
    st = Status{keys(inits)}(values(inits))
    @test all(getproperty(leaf.status, i)[1] == getproperty(st, i) for i in keys(st))
    @test !is_initialized(leaf)
    @test to_initialize(leaf) == (process2=(:var1, :var2,),)
end;

@testset "ModelList with a partially initialized status" begin
    leaf = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        status=(var1=15.0,)
    )

    inits = merge(init_variables(leaf.models)...)
    st = Status{keys(inits)}(values(inits))
    st.var1 = 15.0
    @test all(getproperty(leaf.status, i)[1] == getproperty(st, i) for i in keys(st))
    @test !is_initialized(leaf)
    @test to_initialize(leaf) == (process2=(:var2,),)
end;

@testset "ModelList with fully initialized status" begin
    vals = (var1=15.0, var2=0.3)
    leaf = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        status=vals
    )

    inits = merge(init_variables(leaf.models)...)
    st = Status{keys(inits)}(values(inits))

    for i in keys(vals)
        setproperty!(st, i, getproperty(vals, i))
    end
    @test all(getproperty(leaf.status, i)[1] == getproperty(st, i) for i in keys(st))

    @test is_initialized(leaf)
    @test to_initialize(leaf) == NamedTuple()
end;


@testset "ModelList with independant models (and missing one in the middle)" begin
    vals = (var1=15.0, var2=0.3)
    leaf = ModelList(
        process1=Process1Model(1.0),
        process3=Process3Model(),
        status=vals
    )

    @test to_initialize(leaf) == (process3=(:var5,),)

    # NB: decompose this test because the order of the variables change with the Julia version
    inits = init_variables(leaf)
    sorted_vars = sort([keys(inits.process3)...])

    @test [getfield(inits.process3, i) for i in sorted_vars] ==
          fill(-Inf, 3)
end;
