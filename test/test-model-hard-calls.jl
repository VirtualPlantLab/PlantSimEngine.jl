using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "nested_call_leaf" verbose = false
PlantSimEngine.@process "nested_call_middle" verbose = false
PlantSimEngine.@process "nested_call_root" verbose = false
PlantSimEngine.@process "many_call_controller" verbose = false
PlantSimEngine.@process "call_return_shape" verbose = false

struct NestedCallLeafModel <: AbstractNested_Call_LeafModel end
struct NestedCallMiddleModel <: AbstractNested_Call_MiddleModel end
struct NestedCallRootModel <: AbstractNested_Call_RootModel end
struct ManyCallControllerModel <: AbstractMany_Call_ControllerModel end
struct CallReturnShapeModel <: AbstractCall_Return_ShapeModel end

const CALL_RETURN_CONTEXT = Ref{Any}()

function call_lookup_allocations(context)
    call_targets(context, :one)
    return @allocated call_targets(context, :one)
end

literal_call_targets(context::T) where {T} = call_targets(context, :one)

PlantSimEngine.inputs_(::NestedCallLeafModel) = NamedTuple()
PlantSimEngine.outputs_(::NestedCallLeafModel) = (value=0.0, calls=0)

function PlantSimEngine.run!(
    ::NestedCallLeafModel,
    status,
    environment,
    constants,
    context,
)
    status.calls += 1
    status.value += 1.0
    return nothing
end

PlantSimEngine.inputs_(::NestedCallMiddleModel) = NamedTuple()
PlantSimEngine.outputs_(::NestedCallMiddleModel) = (value=0.0, calls=0)

function PlantSimEngine.run!(
    ::NestedCallMiddleModel,
    status,
    environment,
    constants,
    context,
)
    status.calls += 1
    leaf = only(run_call!(context, :leaf; publish=true))
    status.value = leaf.status.value
    return nothing
end

PlantSimEngine.inputs_(::NestedCallRootModel) = NamedTuple()
PlantSimEngine.outputs_(::NestedCallRootModel) =
    (trial_value=0.0, accepted_value=0.0, calls=0)

function PlantSimEngine.run!(
    ::NestedCallRootModel,
    status,
    environment,
    constants,
    context,
)
    status.calls += 1
    middle = only(call_targets(context, :middle))
    run_call!(middle; publish=false)
    status.trial_value = middle.status.value
    run_call!(middle; publish=true)
    status.accepted_value = middle.status.value
    return nothing
end

PlantSimEngine.inputs_(::ManyCallControllerModel) = NamedTuple()
PlantSimEngine.outputs_(::ManyCallControllerModel) = (total=0.0, ncalls=0)

function PlantSimEngine.run!(
    ::ManyCallControllerModel,
    status,
    environment,
    constants,
    context,
)
    targets = run_call!(context, :children; publish=true)
    status.ncalls = length(targets)
    status.total = sum((target.status.value for target in targets); init=0.0)
    return nothing
end

PlantSimEngine.inputs_(::CallReturnShapeModel) = NamedTuple()
PlantSimEngine.outputs_(::CallReturnShapeModel) = (
    one_count=0,
    optional_count=0,
    many_count=0,
    all_vector_like=false,
    cached_view=false,
)

function PlantSimEngine.run!(
    ::CallReturnShapeModel,
    status,
    environment,
    constants,
    context,
)
    one_targets = run_call!(context, :one; publish=false)
    optional_targets = run_call!(context, :optional; publish=false)
    many_targets = run_call!(context, :many; publish=false)
    status.one_count = length(one_targets)
    status.optional_count = length(optional_targets)
    status.many_count = length(many_targets)
    status.all_vector_like = all(
        targets -> targets isa AbstractVector{CallTarget},
        (one_targets, optional_targets, many_targets),
    )
    status.cached_view = call_targets(context, :one) === call_targets(context, :one)
    CALL_RETURN_CONTEXT[] = context
    return nothing
end

@testset "nested trial publication is transactional" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:middle; scale=:Plant, name=:middle, parent=:scene),
        Object(:leaf; scale=:Leaf, name=:leaf, parent=:middle);
        applications=(
            ModelSpec(NestedCallRootModel(); name=:root, on=One(name=:scene), calls=(:middle => One(name=:middle, within=Subtree(), application=:middle)), every=Hour(1)),
            ModelSpec(NestedCallMiddleModel(); name=:middle, on=One(name=:middle), calls=(:leaf => One(name=:leaf, within=Subtree(), application=:leaf)), every=Hour(1)),
            ModelSpec(NestedCallLeafModel(); name=:leaf, on=One(name=:leaf), every=Hour(1)),
        ),
        environment=(duration=Hour(1),),
    )

    simulation = run!(model; outputs=:all)
    statuses = Dict(object.id.value => object.status for object in model_objects(model))
    @test statuses[:leaf].calls == 2
    @test statuses[:leaf].value == 2.0
    @test statuses[:middle].calls == 2
    @test statuses[:middle].value == 2.0
    @test statuses[:scene].trial_value == 1.0
    @test statuses[:scene].accepted_value == 2.0

    @test length(outputs(simulation)[(:leaf, ObjectId(:leaf), :value)]) == 1
    @test length(outputs(simulation)[(:middle, ObjectId(:middle), :value)]) == 1
    @test only(outputs(simulation)[(:leaf, ObjectId(:leaf), :value)])[2] == 2.0
    @test only(outputs(simulation)[(:middle, ObjectId(:middle), :value)])[2] == 2.0

    schedule = Dict(row.application_id => row for row in explain_schedule(simulation.compiled))
    @test schedule[:middle].manual_call_only
    @test schedule[:leaf].manual_call_only
    @test !schedule[:root].manual_call_only
end


@testset "hard-call return shape and errors" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:leaf_b; scale=:Leaf, name=:leaf_b, parent=:scene),
        Object(:leaf_a; scale=:Leaf, name=:leaf_a, parent=:scene);
        applications=(
            ModelSpec(CallReturnShapeModel(); name=:controller, on=One(name=:scene), calls=(:one => One(name=:leaf_a, application=:leaf_calls),
                    :optional => OptionalOne(
                        name=:missing,
                        application=:leaf_calls,
                    ),
                    :many => Many(scale=:Leaf, application=:leaf_calls),)),
            ModelSpec(NestedCallLeafModel(); name=:leaf_calls, on=Many(scale=:Leaf)),
        ),
        environment=(duration=Hour(1),),
    )

    simulation = run!(model)
    controller = only(model_objects(model; scale=:Scene)).status
    @test controller.one_count == 1
    @test controller.optional_count == 0
    @test controller.many_count == 2
    @test controller.all_vector_like
    @test controller.cached_view
    context = CALL_RETURN_CONTEXT[]
    @test (@inferred literal_call_targets(context)) === call_targets(context, :one)
    call_lookup_allocations(context)
    @test call_lookup_allocations(context) == 0
    one_call_view = call_targets(context, :one)
    @test length(one_call_view.execution_batches) == 1
    cached_execution_target =
        only(only(one_call_view.execution_batches).targets)
    continue!(simulation)
    continued_call_view = call_targets(CALL_RETURN_CONTEXT[], :one)
    @test continued_call_view === one_call_view
    @test only(only(continued_call_view.execution_batches).targets) ===
          cached_execution_target
    register_object!(
        model,
        Object(:leaf_c; scale=:Leaf, name=:leaf_c, parent=:scene),
    )
    continue!(simulation)
    refreshed_call_view = call_targets(CALL_RETURN_CONTEXT[], :one)
    @test only(only(refreshed_call_view.execution_batches).targets) !==
          cached_execution_target
    @test_throws ArgumentError run_call!(nothing, :one)

    undeclared = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            ModelSpec(CallReturnShapeModel(); name=:controller, on=One(scale=:Scene)),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "did not declare call `one`" run!(undeclared)

    zero_one = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=(
            ModelSpec(CallReturnShapeModel(); name=:controller, on=One(scale=:Scene), calls=(:one => One(scale=:Leaf, application=:leaf_calls))),
        ),
    )
    @test_throws "Expected exactly one object" Advanced.refresh_bindings!(zero_one)

    multiple_one = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf_a; scale=:Leaf, parent=:scene),
        Object(:leaf_b; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(CallReturnShapeModel(); name=:controller, on=One(scale=:Scene), calls=(:one => One(scale=:Leaf, application=:leaf_calls))),
            ModelSpec(NestedCallLeafModel(); name=:leaf_calls, on=Many(scale=:Leaf)),
        ),
    )
    @test_throws "Expected exactly one object" Advanced.refresh_bindings!(multiple_one)

    @test_throws "`process=` in scenario" ModelSpec(
        CallReturnShapeModel();
        name=:controller,
        on=One(scale=:Scene),
        calls=(:one => One(scale=:Leaf, process=:nested_call_leaf),),
    )
    @test_throws "`process=` in scenario" ModelSpec(
        CallReturnShapeModel();
        name=:controller,
        on=One(scale=:Scene),
        calls=(
            :optional =>
                OptionalOne(scale=:Leaf, process=:nested_call_leaf),
        ),
    )
end

@testset "Many call targets preserve object identity" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:leaf_b; scale=:Leaf, parent=:scene),
        Object(:leaf_a; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(ManyCallControllerModel(); name=:controller, on=One(name=:scene), calls=(:children => Many(
                        scale=:Leaf,
                        within=SceneScope(),
                        application=:leaf_calls,
                    ),)),
            ModelSpec(NestedCallLeafModel(); name=:leaf_calls, on=Many(scale=:Leaf)),
        ),
        environment=(duration=Hour(1),),
    )

    compiled = Advanced.refresh_bindings!(model)
    call = only(explain_calls(compiled))
    @test call.callee_object_ids == [:leaf_a, :leaf_b]
    @test call.callee_application_ids == [:leaf_calls]

    simulation = run!(model; outputs=:all)
    controller = only(model_objects(model; scale=:Scene)).status
    @test controller.ncalls == 2
    @test controller.total == 2.0
    rows = filter(
        row -> row.application_id == :leaf_calls && row.variable == :value,
        collect_outputs(simulation; sink=nothing),
    )
    @test getproperty.(rows, :object_id) == [:leaf_a, :leaf_b]
    @test getproperty.(rows, :value) == [1.0, 1.0]

    register_object!(
        model,
        Object(:leaf_c; scale=:Leaf, parent=:scene),
    )
    continue!(simulation; steps=1)
    @test controller.ncalls == 3
    @test controller.total == 5.0

    remove_object!(model, :leaf_b)
    continue!(simulation; steps=1)
    @test controller.ncalls == 2
    @test controller.total == 5.0
end

@testset "call targets refresh after reparenting" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_a; scale=:Plant, name=:plant_a, parent=:scene),
        Object(:plant_b; scale=:Plant, name=:plant_b, parent=:scene),
        Object(:leaf; scale=:Leaf, parent=:plant_b);
        applications=(
            ModelSpec(ManyCallControllerModel(); name=:controller, on=One(name=:plant_a), calls=(:children => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:leaf_calls,
                    ),)),
            ModelSpec(NestedCallLeafModel(); name=:leaf_calls, on=Many(scale=:Leaf)),
        ),
        environment=(duration=Hour(1),),
    )

    simulation = run!(model)
    controller = only(model_objects(model; name=:plant_a)).status
    schedule = Dict(row.application_id => row for row in explain_schedule(simulation.compiled))
    @test schedule[:leaf_calls].manual_call_only
    @test !schedule[:leaf_calls].root_scheduled
    @test controller.ncalls == 0

    reparent_object!(model, :leaf, :plant_a)
    continue!(simulation; steps=1)
    @test controller.ncalls == 1
    @test controller.total == 1.0

    reparent_object!(model, :leaf, :plant_b)
    continue!(simulation; steps=1)
    @test controller.ncalls == 0
    @test controller.total == 0.0
end

@testset "manual target cadence contract" begin
    incompatible = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:leaf; scale=:Leaf, name=:leaf, parent=:scene);
        applications=(
            ModelSpec(ManyCallControllerModel(); name=:controller, on=One(name=:scene), calls=(:children => One(name=:leaf, application=:leaf_calls)), every=Day(1)),
            ModelSpec(NestedCallLeafModel(); name=:leaf_calls, on=One(name=:leaf), every=Hour(1)),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "incompatible cadence" Advanced.refresh_bindings!(incompatible)

    inherited = CompositeModel(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:leaf; scale=:Leaf, name=:leaf, parent=:scene);
        applications=(
            ModelSpec(ManyCallControllerModel(); name=:controller, on=One(name=:scene), calls=(:children => One(name=:leaf, application=:leaf_calls)), every=Day(1)),
            ModelSpec(NestedCallLeafModel(); name=:leaf_calls, on=One(name=:leaf)),
        ),
        environment=(duration=Hour(1),),
    )
    @test_nowarn Advanced.refresh_bindings!(inherited)
end
