# include(joinpath(pkgdir(PlantSimEngine), "examples/dummy.jl"))

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
    @test to_initialize(leaf) == (process1=(:var1, :var2), process2=(:var1,))
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
    @test to_initialize(leaf) == (process1=(:var2,),)
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

@testset "Copy a ModelList" begin
    vars = (var1=15.0, var2=0.3)
    # Create a model list:
    models = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        status=vars
    )

    # Copy the model list:
    ml2 = copy(models)

    @test DataFrame(status(ml2)) == DataFrame(status(models))

    # Copy the model list with new status:
    tst = TimeStepTable([Status(var1=20.0, var2=0.5)])
    ml3 = copy(models, tst)

    @test status(ml3) == tst
    @test ml3.models == models.models


    cp_models = copy([models, ml3])
    @test cp_models == [models, ml3]

    cp_models = copy(Dict("models" => models, "ml3" => ml3))
    @test cp_models == Dict("models" => models, "ml3" => ml3)
end;

@testset "Convert ModelList status variables into new types" begin
    ref_vars = init_variables(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
    )
    type_promotion = Dict(Real => Float32)

    process3_Float32 = PlantSimEngine.convert_vars(type_promotion, ref_vars.process3)

    @test all([isa(getfield(process3_Float32, i), Float32) for i in keys(process3_Float32)])

    process3_same = PlantSimEngine.convert_vars(nothing, ref_vars.process3)
    @test process3_same == ref_vars.process3
end


@testset "ModelList dependencies" begin

    models = ModelList(
        process1=Process1Model(1.0),
        process2=Process2Model(),
        process3=Process3Model(),
        process4=Process4Model(),
        process5=Process5Model(),
        process6=Process6Model(),
        status=(var1=15.0, var2=0.3)
    )

    deps = dep(models).roots
    @test collect(keys(deps)) == [:process3, :process4]

    @test deps[:process4].value == Process4Model()
    @test isa(deps[:process4], PlantSimEngine.SoftDependencyNode)

    @test deps[:process3].value == Process3Model()
    @test isa(deps[:process3], PlantSimEngine.SoftDependencyNode)

    @test deps[:process3].hard_dependency[1].value == Process2Model()
    @test isa(deps[:process3].hard_dependency[1], PlantSimEngine.HardDependencyNode)

    @test deps[:process3].hard_dependency[1].children[1].value == Process1Model(1.0)
    @test isa(deps[:process3].hard_dependency[1].children[1], PlantSimEngine.HardDependencyNode)

    @test deps[:process3].children[1].value == Process5Model()
    @test isa(deps[:process3].children[1], PlantSimEngine.SoftDependencyNode)
end