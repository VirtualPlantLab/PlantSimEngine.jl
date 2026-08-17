PlantSimEngine.@process "source_compiler_signal" verbose = false
struct SourceCompilerSignalModel <: AbstractSource_Compiler_SignalModel end

PlantSimEngine.inputs_(::SourceCompilerSignalModel) = NamedTuple()
PlantSimEngine.outputs_(::SourceCompilerSignalModel) = (signal=0.0,)

function PlantSimEngine.run!(
    ::SourceCompilerSignalModel,
    status,
    environment,
    constants,
    context,
)
    status.signal += 1.0
    return nothing
end

PlantSimEngine.@process "source_compiler_consumer" verbose = false
struct SourceCompilerConsumerModel <: AbstractSource_Compiler_ConsumerModel end

PlantSimEngine.inputs_(::SourceCompilerConsumerModel) = (signal=Required(Real),)
PlantSimEngine.outputs_(::SourceCompilerConsumerModel) = (doubled=0.0,)

function PlantSimEngine.run!(
    ::SourceCompilerConsumerModel,
    status,
    environment,
    constants,
    context,
)
    status.doubled = 2.0 * status.signal
    return nothing
end

PlantSimEngine.@process "source_compiler_child" verbose = false
struct SourceCompilerChildModel <: AbstractSource_Compiler_ChildModel end

PlantSimEngine.inputs_(::SourceCompilerChildModel) = NamedTuple()
PlantSimEngine.outputs_(::SourceCompilerChildModel) = (child_value=0.0,)

function PlantSimEngine.run!(
    ::SourceCompilerChildModel,
    status,
    environment,
    constants,
    context,
)
    status.child_value += 3.0
    return nothing
end

PlantSimEngine.@process "source_compiler_parent" verbose = false
struct SourceCompilerParentModel <: AbstractSource_Compiler_ParentModel end

PlantSimEngine.inputs_(::SourceCompilerParentModel) = NamedTuple()
PlantSimEngine.outputs_(::SourceCompilerParentModel) = (parent_value=0.0,)

function PlantSimEngine.run!(
    ::SourceCompilerParentModel,
    status,
    environment,
    constants,
    context,
)
    child = only(run_call!(context, :child; publish=true))
    status.parent_value = child.status.child_value + 1.0
    return nothing
end

PlantSimEngine.@process "source_compiler_leaf" verbose = false
struct SourceCompilerLeafModel <: AbstractSource_Compiler_LeafModel end

PlantSimEngine.inputs_(::SourceCompilerLeafModel) = NamedTuple()
PlantSimEngine.outputs_(::SourceCompilerLeafModel) = (leaf_value=0.0,)

function PlantSimEngine.run!(
    ::SourceCompilerLeafModel,
    status,
    environment,
    constants,
    context,
)
    status.leaf_value += 0.5
    return nothing
end

function source_compiler_fixture()
    return CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf_1; scale=:Leaf, kind=:leaf, parent=:scene),
        Object(:leaf_2; scale=:Leaf, kind=:leaf, parent=:scene);
        applications=(
            ModelSpec(
                SourceCompilerSignalModel();
                name=:source,
                on=One(scale=:Scene),
            ),
            ModelSpec(
                SourceCompilerConsumerModel();
                name=:consumer,
                on=One(scale=:Scene),
            ),
            ModelSpec(
                SourceCompilerChildModel();
                name=:child,
                on=One(scale=:Scene),
            ),
            ModelSpec(
                SourceCompilerParentModel();
                name=:parent,
                on=One(scale=:Scene),
                calls=(
                    child=One(
                        scale=:Scene,
                        within=Self(),
                        application=:child,
                    ),
                ),
            ),
            ModelSpec(
                SourceCompilerLeafModel();
                name=:leaf_growth,
                on=Many(scale=:Leaf),
            ),
        ),
    )
end

@testset "Readable CompositeModel source generation" begin
    model = source_compiler_fixture()
    source = compile_model_source(model; function_name=:readable_source_model!)

    @test source == compile_model_source(
        source_compiler_fixture();
        function_name=:readable_source_model!,
    )
    @test occursin("executable explanation of a resolved CompositeModel", source)
    @test occursin("Application :source", source)
    @test occursin("Application :consumer", source)
    @test occursin("Application :child", source)
    @test occursin("Application :parent", source)
    @test occursin("Application :leaf_growth", source)
    @test occursin("input :signal <- application :source.signal via one", source)
    @test occursin("manual call :child -> application :child via one", source)
    @test occursin("current targets: leaf_1", source)
    @test occursin("leaf_2", source)
    @test occursin("status.doubled = 2.0 * status.signal", source)
    @test occursin("status.child_value += 3.0", source)
    @test occursin("PlantSimEngine._compiled_source_run_call!", source)
    @test !occursin("_run_model_execution_batch!", source)

    path = tempname() * ".jl"
    @test write_compiled_model(
        path,
        source_compiler_fixture();
        function_name=:readable_source_model!,
    ) == path
    @test read(path, String) == source

    generated_module = Module(gensym(:ReadableSourceModel))
    Base.include(generated_module, path)
    generated_run = Core.eval(generated_module, :readable_source_model!)

    generated_simulation = generated_run(
        source_compiler_fixture();
        steps=3,
        outputs=:all,
    )
    normal_simulation = run!(
        source_compiler_fixture();
        steps=3,
        outputs=:all,
    )

    generated_scene = final_state(generated_simulation, One(scale=:Scene))
    normal_scene = final_state(normal_simulation, One(scale=:Scene))
    @test generated_simulation.current_step == normal_simulation.current_step == 3
    @test generated_scene.signal == normal_scene.signal == 3.0
    @test generated_scene.doubled == normal_scene.doubled == 6.0
    @test generated_scene.child_value == normal_scene.child_value == 9.0
    @test generated_scene.parent_value == normal_scene.parent_value == 10.0

    generated_leaves = final_state(generated_simulation, Many(scale=:Leaf))
    normal_leaves = final_state(normal_simulation, Many(scale=:Leaf))
    generated_leaf_values = [
        generated_leaves[id].leaf_value for
        id in sort!(collect(keys(generated_leaves)))
    ]
    normal_leaf_values = [
        normal_leaves[id].leaf_value for
        id in sort!(collect(keys(normal_leaves)))
    ]
    @test generated_leaf_values == normal_leaf_values == [1.5, 1.5]
    @test collect_outputs(generated_simulation; sink=nothing) ==
          collect_outputs(normal_simulation; sink=nothing)
end

@testset "Readable source compatibility guard" begin
    source = compile_model_source(
        source_compiler_fixture();
        function_name=:guarded_source_model!,
    )
    path = tempname() * ".jl"
    write(path, source)
    generated_module = Module(gensym(:GuardedSourceModel))
    Base.include(generated_module, path)
    generated_run = Core.eval(generated_module, :guarded_source_model!)

    incompatible = CompositeModel(
        SourceCompilerSignalModel();
        status=NamedTuple(),
    )
    @test_throws "Generated model source is incompatible" generated_run(incompatible)
    @test_throws "valid Julia identifier" compile_model_source(
        source_compiler_fixture();
        function_name=Symbol("not valid"),
    )
end
