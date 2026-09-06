using Dates

PlantSimEngine.@process "source_compiler_signal" verbose = false
struct SourceCompilerSignalModel <: AbstractSource_Compiler_SignalModel end

PlantSimEngine.@process "source_compiler_generic" verbose = false
struct SourceCompilerGenericModel{T} <: AbstractSource_Compiler_GenericModel end

SourceCompilerGenericModel() = SourceCompilerGenericModel{Float32}()

PlantSimEngine.inputs_(::SourceCompilerGenericModel) = NamedTuple()
PlantSimEngine.outputs_(::SourceCompilerGenericModel{T}) where {T} =
    (generic_value=zero(T),)

function PlantSimEngine.run!(
    ::M,
    status,
    environment,
    constants,
    context,
) where {T,M<:SourceCompilerGenericModel{T}}
    @debug "Running the generic source-compiler fixture"
    isnothing(nothing) || error("literal `nothing` was not preserved")
    status.generic_value > T(10) && return
    status.generic_value += T(4)
    return nothing
end

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

PlantSimEngine.@process "source_compiler_grandchild" verbose = false
struct SourceCompilerGrandchildModel <:
       AbstractSource_Compiler_GrandchildModel end

PlantSimEngine.inputs_(::SourceCompilerGrandchildModel) = NamedTuple()
PlantSimEngine.outputs_(::SourceCompilerGrandchildModel) = (grandchild_value=0.0,)
PlantSimEngine.environment_inputs_(::SourceCompilerGrandchildModel) = (T=0.0,)

function PlantSimEngine.run!(
    ::SourceCompilerGrandchildModel,
    status,
    environment,
    constants,
    context,
)
    status.grandchild_value += environment.T
    return nothing
end

PlantSimEngine.inputs_(::SourceCompilerChildModel) = NamedTuple()
PlantSimEngine.outputs_(::SourceCompilerChildModel) = (child_value=0.0,)

function PlantSimEngine.run!(
    ::SourceCompilerChildModel,
    status,
    environment,
    constants,
    context,
)
    grandchild = only(call_targets(context, :grandchild))
    run_call!(
        grandchild;
        sampled_environment=(T=2.0,),
        publish=true,
    )
    status.child_value += grandchild.status.grandchild_value + 1.0
    return nothing
end

PlantSimEngine.@process "source_compiler_parent" verbose = false
struct SourceCompilerParentModel <: AbstractSource_Compiler_ParentModel end

PlantSimEngine.@process "source_compiler_alias_parent" verbose = false
struct SourceCompilerAliasParentModel <:
       AbstractSource_Compiler_Alias_ParentModel end

PlantSimEngine.inputs_(::SourceCompilerAliasParentModel) = NamedTuple()
PlantSimEngine.outputs_(::SourceCompilerAliasParentModel) = (alias_value=0.0,)

function PlantSimEngine.run!(
    ::SourceCompilerAliasParentModel,
    status,
    environment,
    constants,
    context,
)
    runner = run_call!
    runner(context, :child)
    status.alias_value += 1.0
    return nothing
end

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

PlantSimEngine.@process "source_compiler_bound_many" verbose = false
struct SourceCompilerBoundManyModel <: AbstractSource_Compiler_Bound_ManyModel end

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

PlantSimEngine.inputs_(::SourceCompilerBoundManyModel) = (
    leaf_values=Required(Vector{Float64}),
)
PlantSimEngine.outputs_(::SourceCompilerBoundManyModel) = (
    bound_total=0.0,
    bound_count=0,
)

function PlantSimEngine.run!(
    ::SourceCompilerBoundManyModel,
    status,
    environment,
    constants,
    context,
)
    leaves = bound_input(context, :leaf_values)
    status.bound_total = sum(leaves; init=0.0)
    status.bound_count = length(object_ids(leaves))
    return nothing
end

PlantSimEngine.@process "source_compiler_spawner" verbose = false
struct SourceCompilerSpawnerModel <: AbstractSource_Compiler_SpawnerModel
    leaf_id::Symbol
end

PlantSimEngine.inputs_(::SourceCompilerSpawnerModel) = NamedTuple()
PlantSimEngine.outputs_(::SourceCompilerSpawnerModel) = (created=0,)

function PlantSimEngine.run!(
    model::SourceCompilerSpawnerModel,
    status,
    environment,
    constants,
    context,
)
    runtime = runtime_model(context)
    ObjectId(model.leaf_id) in object_ids(runtime) && return nothing
    register_object!(
        runtime,
        Object(
            model.leaf_id;
            scale=:Leaf,
            kind=:leaf,
            parent=:scene,
        ),
    )
    status.created += 1
    return nothing
end

PlantSimEngine.@process "source_compiler_lagged" verbose = false
struct SourceCompilerLaggedModel <: AbstractSource_Compiler_LaggedModel end

PlantSimEngine.@process "source_compiler_initializer_leaf" verbose = false
struct SourceCompilerInitializerLeafModel <:
       AbstractSource_Compiler_Initializer_LeafModel end

PlantSimEngine.inputs_(::SourceCompilerInitializerLeafModel) = NamedTuple()
PlantSimEngine.outputs_(::SourceCompilerInitializerLeafModel) = (initialized_runs=0,)

function PlantSimEngine.run!(
    ::SourceCompilerInitializerLeafModel,
    status,
    environment,
    constants,
    context,
)
    status.initialized_runs += one(status.initialized_runs)
    return nothing
end

PlantSimEngine.@process "source_compiler_initializer_creator" verbose = false
struct SourceCompilerInitializerCreatorModel <:
       AbstractSource_Compiler_Initializer_CreatorModel end

PlantSimEngine.inputs_(::SourceCompilerInitializerCreatorModel) = NamedTuple()
PlantSimEngine.outputs_(::SourceCompilerInitializerCreatorModel) = (
    created=false,
    initialized_runs_seen=0,
)

function PlantSimEngine.run!(
    ::SourceCompilerInitializerCreatorModel,
    status,
    environment,
    constants,
    context,
)
    status.created && return nothing
    leaf = register_object!(
        runtime_model(context),
        Object(:initialized_leaf; scale=:Leaf, kind=:leaf, parent=:scene),
    )
    initialized = run_initializer!(context, :leaf, leaf)
    status.initialized_runs_seen = initialized.initialized_runs
    status.created = true
    return nothing
end

PlantSimEngine.inputs_(::SourceCompilerLaggedModel) =
    (signal=Required(Real),)
PlantSimEngine.outputs_(::SourceCompilerLaggedModel) =
    (lagged_signal=0.0, lagged_runs=0)

function PlantSimEngine.run!(
    ::SourceCompilerLaggedModel,
    status,
    environment,
    constants,
    context,
)
    status.lagged_signal = status.signal
    status.lagged_runs += 1
    return nothing
end

PlantSimEngine.@process "source_compiler_environment" verbose = false
struct SourceCompilerEnvironmentModel <:
       AbstractSource_Compiler_EnvironmentModel end

PlantSimEngine.@process "source_compiler_distributed" verbose = false
struct SourceCompilerDistributedModel <:
       AbstractSource_Compiler_DistributedModel end

PlantSimEngine.inputs_(::SourceCompilerEnvironmentModel) = NamedTuple()
PlantSimEngine.outputs_(::SourceCompilerEnvironmentModel) =
    (temperature_seen=0.0, environment_runs=0)
PlantSimEngine.environment_inputs_(::SourceCompilerEnvironmentModel) = (T=0.0,)

function PlantSimEngine.run!(
    ::SourceCompilerEnvironmentModel,
    status,
    environment,
    constants,
    context,
)
    status.temperature_seen = environment.T
    status.environment_runs += 1
    return nothing
end

PlantSimEngine.inputs_(::SourceCompilerDistributedModel) = NamedTuple()
PlantSimEngine.outputs_(::SourceCompilerDistributedModel) = (local_value=0.0,)

function PlantSimEngine.run!(
    ::SourceCompilerDistributedModel,
    status,
    environment,
    constants,
    context,
)
    status.local_value += one(status.local_value)
    leaves = output_targets(context, :leaves)
    for index in eachindex(leaves.columns.distributed_value)
        leaves.columns.distributed_value[index] =
            status.local_value + convert(typeof(status.local_value), index)
    end
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
                SourceCompilerGenericModel();
                name=:generic_dispatch,
                on=One(scale=:Scene),
            ),
            ModelSpec(
                SourceCompilerConsumerModel();
                name=:consumer,
                on=One(scale=:Scene),
            ),
            ModelSpec(
                SourceCompilerGrandchildModel();
                name=:grandchild,
                on=One(scale=:Scene),
            ),
            ModelSpec(
                SourceCompilerChildModel();
                name=:child,
                on=One(scale=:Scene),
                calls=(
                    grandchild=One(
                        scale=:Scene,
                        within=Self(),
                        application=:grandchild,
                    ),
                ),
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
            ModelSpec(
                SourceCompilerBoundManyModel();
                name=:bound_many,
                on=One(scale=:Scene),
                inputs=(
                    leaf_values=Many(
                        scale=:Leaf,
                        within=SceneScope(),
                        application=:leaf_growth,
                        var=:leaf_value,
                    ),
                ),
            ),
        ),
        environment=(T=0.0, duration=1.0),
    )
end

function source_compiler_lifecycle_fixture()
    return CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene);
        applications=(
            ModelSpec(
                SourceCompilerSpawnerModel(:leaf_1);
                name=:spawn_leaf,
                on=One(scale=:Scene),
            ),
            ModelSpec(
                SourceCompilerLeafModel();
                name=:leaf_growth,
                on=Many(scale=:Leaf),
            ),
        ),
    )
end

function source_compiler_temporal_fixture()
    return CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene);
        applications=(
            ModelSpec(
                SourceCompilerSignalModel();
                name=:source,
                on=One(scale=:Scene),
                every=Hour(1),
            ),
            ModelSpec(
                SourceCompilerSignalModel();
                name=:stream_source,
                on=One(scale=:Scene),
                every=Hour(1),
                output_routing=(signal=:stream_only,),
            ),
            ModelSpec(
                SourceCompilerLaggedModel();
                name=:lagged,
                on=One(scale=:Scene),
                inputs=(
                    PreviousTimeStep(:signal) => One(
                        scale=:Scene,
                        within=Self(),
                        application=:source,
                        var=:signal,
                        policy=HoldLast(),
                    ),
                ),
                every=Hour(2),
            ),
            ModelSpec(
                SourceCompilerEnvironmentModel();
                name=:environment_probe,
                on=One(scale=:Scene),
                every=Hour(2),
                environment=Environment(provider=:global),
            ),
        ),
        environment=(T=18.5, duration=Hour(1)),
    )
end

function source_compiler_initializer_fixture()
    return CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene);
        applications=(
            ModelSpec(
                SourceCompilerInitializerLeafModel();
                name=:leaf_initializer,
                on=Many(scale=:Leaf),
            ),
            ModelSpec(
                SourceCompilerInitializerCreatorModel();
                name=:initializer_creator,
                on=One(scale=:Scene),
                calls=(
                    leaf=Initializer(
                        One(scale=:Leaf, application=:leaf_initializer),
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
    )
end

function source_compiler_unsupported_call_fixture()
    return CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            ModelSpec(
                SourceCompilerChildModel();
                name=:child,
                on=One(scale=:Scene),
            ),
            ModelSpec(
                SourceCompilerAliasParentModel();
                name=:alias_parent,
                on=One(scale=:Scene),
                calls=(
                    child=One(
                        scale=:Scene,
                        within=Self(),
                        application=:child,
                    ),
                ),
            ),
        ),
    )
end

function source_compiler_distributed_fixture()
    return CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf_1; scale=:Leaf, parent=:scene),
        Object(:leaf_2; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(
                SourceCompilerDistributedModel();
                name=:distributed,
                on=One(scale=:Scene),
                outputs_to=(
                    leaves=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=(distributed_value=Default(0.0),),
                    ),
                ),
            ),
        ),
        environment=(duration=Hour(1),),
        type_promotion=Dict(Float64 => Float32),
    )
end

@testset "Readable CompositeModel source generation" begin
    model = source_compiler_fixture()
    source = Authoring.compiled_model_source(model; function_name=:readable_source_model!)

    @test source == Authoring.compiled_model_source(
        source_compiler_fixture();
        function_name=:readable_source_model!,
    )
    @test occursin("executable explanation of a resolved CompositeModel", source)
    @test occursin("Application :source", source)
    @test occursin("Application :consumer", source)
    @test occursin("Application :generic_dispatch", source)
    @test occursin("Application :child", source)
    @test occursin("Application :grandchild", source)
    @test occursin("Application :parent", source)
    @test occursin("Application :leaf_growth", source)
    @test occursin("Application :bound_many", source)
    @test occursin("input :signal <- application :source.signal via one", source)
    @test occursin("manual call :child -> application :child via one", source)
    @test occursin(
        "manual call :grandchild -> application :grandchild via one",
        source,
    )
    @test occursin("current targets: leaf_1", source)
    @test occursin("leaf_2", source)
    @test occursin("status.doubled = 2.0 * status.signal", source)
    @test occursin(
        "status.child_value += grandchild.status.grandchild_value + 1.0",
        source,
    )
    @test occursin("sampled_environment = (T = 2.0,)", source)
    @test occursin("isnothing(nothing)", source)
    @test occursin("PlantSimEngine._compiled_source_run_call!", source)
    @test !occursin("_run_model_execution_batch!", source)
    @test !occursin("group.batches", source)
    @test !occursin("CompiledExecutionBatch", source)

    path = tempname() * ".jl"
    @test Authoring.write_compiled_model_source(
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
    @test generated_scene.generic_value == normal_scene.generic_value == 12.0
    @test generated_scene.generic_value === normal_scene.generic_value === Float32(12)
    @test generated_scene.doubled == normal_scene.doubled == 6.0
    @test generated_scene.grandchild_value == normal_scene.grandchild_value == 6.0
    @test generated_scene.child_value == normal_scene.child_value == 15.0
    @test generated_scene.parent_value == normal_scene.parent_value == 16.0
    @test generated_scene.bound_total == normal_scene.bound_total == 3.0
    @test generated_scene.bound_count == normal_scene.bound_count == 2

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

    # Exercise the generic method's short-circuit bare `return` after the
    # source has already crossed its threshold.
    generated_run(generated_simulation)
    continue!(normal_simulation)
    @test final_state(generated_simulation, :scene).generic_value ==
          final_state(normal_simulation, :scene).generic_value == 12.0
    @test collect_outputs(generated_simulation; sink=nothing) ==
          collect_outputs(normal_simulation; sink=nothing)
end


@testset "Readable source newborn initializer parity" begin
    model = source_compiler_initializer_fixture()
    signature = PlantSimEngine._compiled_source_scenario_signature(
        Advanced.refresh_bindings!(model),
    )
    @test only(signature.calls).mode === :initializer

    source = Authoring.compiled_model_source(
        model;
        function_name=:initializer_source_model!,
    )
    @test occursin("initializer :leaf -> application :leaf_initializer", source)
    @test occursin("PlantSimEngine._compiled_source_run_initializer!", source)
    @test !occursin("run_initializer!(context, :leaf, leaf)", source)

    path = tempname() * ".jl"
    write(path, source)
    generated_module = Module(gensym(:InitializerSourceModel))
    Base.include(generated_module, path)
    generated_run = Core.eval(generated_module, :initializer_source_model!)

    generated_simulation = generated_run(
        source_compiler_initializer_fixture();
        outputs=:all,
    )
    normal_simulation = run!(
        source_compiler_initializer_fixture();
        outputs=:all,
    )

    @test final_state(generated_simulation, :scene).initialized_runs_seen ==
          final_state(normal_simulation, :scene).initialized_runs_seen == 1
    @test final_state(generated_simulation, :initialized_leaf).initialized_runs ==
          final_state(normal_simulation, :initialized_leaf).initialized_runs == 1
    @test collect_outputs(generated_simulation; sink=nothing) ==
          collect_outputs(normal_simulation; sink=nothing)
end


@testset "Readable source lifecycle refresh" begin
    source = Authoring.compiled_model_source(
        source_compiler_lifecycle_fixture();
        function_name=:lifecycle_source_model!,
    )
    @test occursin("current targets: none", source)
    @test occursin("lifecycle revision", source)

    path = tempname() * ".jl"
    write(path, source)
    generated_module = Module(gensym(:LifecycleSourceModel))
    Base.include(generated_module, path)
    generated_run = Core.eval(generated_module, :lifecycle_source_model!)

    generated_simulation = generated_run(
        source_compiler_lifecycle_fixture();
        outputs=:all,
    )
    normal_simulation = run!(
        source_compiler_lifecycle_fixture();
        outputs=:all,
    )

    generated_leaf = final_state(generated_simulation, One(scale=:Leaf))
    normal_leaf = final_state(normal_simulation, One(scale=:Leaf))
    @test generated_leaf.leaf_value == normal_leaf.leaf_value == 0.5
    @test final_state(generated_simulation, One(scale=:Scene)).created == 1
    @test collect_outputs(generated_simulation; sink=nothing) ==
          collect_outputs(normal_simulation; sink=nothing)

    register_object!(
        runtime_model(generated_simulation),
        Object(:leaf_2; scale=:Leaf, kind=:leaf, parent=:scene),
    )
    register_object!(
        runtime_model(normal_simulation),
        Object(:leaf_2; scale=:Leaf, kind=:leaf, parent=:scene),
    )
    generated_run(generated_simulation)
    continue!(normal_simulation)
    @test final_state(generated_simulation, :leaf_2).leaf_value == 0.5

    remove_object!(runtime_model(generated_simulation), :leaf_1)
    remove_object!(runtime_model(normal_simulation), :leaf_1)
    generated_run(generated_simulation)
    continue!(normal_simulation)
    @test final_state(generated_simulation, :leaf_2).leaf_value == 1.0
    @test collect_outputs(generated_simulation; sink=nothing) ==
          collect_outputs(normal_simulation; sink=nothing)
end

@testset "Readable source temporal, environment, and continuation parity" begin
    source = Authoring.compiled_model_source(
        source_compiler_temporal_fixture();
        function_name=:temporal_source_model!,
    )
    @test occursin("previous timestep", source)
    @test occursin("policy=PreviousTimeStep(:signal)", source)
    @test occursin("output routing: signal=>:stream_only", source)
    @test occursin("environment: Environment(provider=:global)", source)

    path = tempname() * ".jl"
    write(path, source)
    generated_module = Module(gensym(:TemporalSourceModel))
    Base.include(generated_module, path)
    generated_run = Core.eval(generated_module, :temporal_source_model!)

    generated_simulation = generated_run(
        source_compiler_temporal_fixture();
        steps=1,
        outputs=:all,
    )
    generated_run(generated_simulation; steps=4)

    normal_simulation = run!(
        source_compiler_temporal_fixture();
        steps=1,
        outputs=:all,
    )
    continue!(normal_simulation; steps=4)

    generated_scene = final_state(generated_simulation, One(scale=:Scene))
    normal_scene = final_state(normal_simulation, One(scale=:Scene))
    @test current_step(generated_simulation) == current_step(normal_simulation) == 5
    @test generated_scene.lagged_signal == normal_scene.lagged_signal
    @test generated_scene.lagged_runs == normal_scene.lagged_runs
    @test generated_scene.temperature_seen == normal_scene.temperature_seen == 18.5
    @test generated_scene.environment_runs == normal_scene.environment_runs
    @test collect_outputs(generated_simulation; sink=nothing) ==
          collect_outputs(normal_simulation; sink=nothing)
end

@testset "Readable source compatibility guard" begin
    source = Authoring.compiled_model_source(
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
    @test_throws "valid Julia identifier" Authoring.compiled_model_source(
        source_compiler_fixture();
        function_name=Symbol("not valid"),
    )
    @test_throws "unsupported call shape" Authoring.compiled_model_source(
        source_compiler_unsupported_call_fixture(),
    )
end

@testset "Readable source status conversion and distributed output parity" begin
    source = Authoring.compiled_model_source(
        source_compiler_distributed_fixture();
        function_name=:distributed_source_model!,
    )
    @test occursin("distributed outputs: leaves=>", source)
    path = tempname() * ".jl"
    write(path, source)
    generated_module = Module(gensym(:DistributedSourceModel))
    Base.include(generated_module, path)
    generated_run = Core.eval(generated_module, :distributed_source_model!)

    generated_simulation = generated_run(
        source_compiler_distributed_fixture();
        steps=2,
        outputs=:all,
    )
    normal_simulation = run!(
        source_compiler_distributed_fixture();
        steps=2,
        outputs=:all,
    )

    @test final_state(generated_simulation, :scene).local_value ===
          final_state(normal_simulation, :scene).local_value === Float32(2)
    @test final_state(generated_simulation, :leaf_1).distributed_value ===
          final_state(normal_simulation, :leaf_1).distributed_value === Float32(3)
    @test final_state(generated_simulation, :leaf_2).distributed_value ===
          final_state(normal_simulation, :leaf_2).distributed_value === Float32(4)
    @test collect_outputs(generated_simulation; sink=nothing) ==
          collect_outputs(normal_simulation; sink=nothing)
end
