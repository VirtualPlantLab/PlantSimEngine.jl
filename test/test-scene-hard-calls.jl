using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "nested_call_leaf" verbose = false
PlantSimEngine.@process "nested_call_middle" verbose = false
PlantSimEngine.@process "nested_call_root" verbose = false
PlantSimEngine.@process "many_call_controller" verbose = false

struct NestedCallLeafModel <: AbstractNested_Call_LeafModel end
struct NestedCallMiddleModel <: AbstractNested_Call_MiddleModel end
struct NestedCallRootModel <: AbstractNested_Call_RootModel end
struct ManyCallControllerModel <: AbstractMany_Call_ControllerModel end

PlantSimEngine.inputs_(::NestedCallLeafModel) = NamedTuple()
PlantSimEngine.outputs_(::NestedCallLeafModel) = (value=0.0, calls=0)

function PlantSimEngine.run!(
    ::NestedCallLeafModel,
    models,
    status,
    meteo,
    constants,
    extra,
)
    status.calls += 1
    status.value += 1.0
    return nothing
end

PlantSimEngine.inputs_(::NestedCallMiddleModel) = NamedTuple()
PlantSimEngine.outputs_(::NestedCallMiddleModel) = (value=0.0, calls=0)

function PlantSimEngine.run!(
    ::NestedCallMiddleModel,
    models,
    status,
    meteo,
    constants,
    extra,
)
    status.calls += 1
    leaf = call_target(extra, :leaf)
    run_call!(leaf; publish=true)
    status.value = leaf.status.value
    return nothing
end

PlantSimEngine.inputs_(::NestedCallRootModel) = NamedTuple()
PlantSimEngine.outputs_(::NestedCallRootModel) =
    (trial_value=0.0, accepted_value=0.0, calls=0)

function PlantSimEngine.run!(
    ::NestedCallRootModel,
    models,
    status,
    meteo,
    constants,
    extra,
)
    status.calls += 1
    middle = call_target(extra, :middle)
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
    models,
    status,
    meteo,
    constants,
    extra,
)
    targets = call_targets(extra, :children)
    status.ncalls = length(targets)
    for target in targets
        run_call!(target; publish=true)
    end
    status.total = sum(target.status.value for target in targets)
    return nothing
end

@testset "nested trial publication is transactional" begin
    scene = Scene(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:middle; scale=:Plant, name=:middle, parent=:scene),
        Object(:leaf; scale=:Leaf, name=:leaf, parent=:middle);
        applications=(
            ModelSpec(NestedCallRootModel(); name=:root) |>
                AppliesTo(One(name=:scene)) |>
                Calls(:middle => One(name=:middle, within=Subtree(), application=:middle)) |>
                TimeStep(Hour(1)),
            ModelSpec(NestedCallMiddleModel(); name=:middle) |>
                AppliesTo(One(name=:middle)) |>
                Calls(:leaf => One(name=:leaf, within=Subtree(), application=:leaf)) |>
                TimeStep(Hour(1)),
            ModelSpec(NestedCallLeafModel(); name=:leaf) |>
                AppliesTo(One(name=:leaf)) |>
                TimeStep(Hour(1)),
        ),
        environment=(duration=Hour(1),),
    )

    simulation = run!(scene; outputs=:all)
    statuses = Dict(object.id.value => object.status for object in scene_objects(scene))
    @test statuses[:leaf].calls == 2
    @test statuses[:leaf].value == 2.0
    @test statuses[:middle].calls == 2
    @test statuses[:middle].value == 2.0
    @test statuses[:scene].trial_value == 1.0
    @test statuses[:scene].accepted_value == 2.0

    @test length(scene_outputs(simulation)[(:leaf, ObjectId(:leaf), :value)]) == 1
    @test length(scene_outputs(simulation)[(:middle, ObjectId(:middle), :value)]) == 1
    @test only(scene_outputs(simulation)[(:leaf, ObjectId(:leaf), :value)])[2] == 2.0
    @test only(scene_outputs(simulation)[(:middle, ObjectId(:middle), :value)])[2] == 2.0

    schedule = Dict(row.application_id => row for row in explain_schedule(simulation.compiled))
    @test schedule[:middle].manual_call_only
    @test schedule[:leaf].manual_call_only
    @test !schedule[:root].manual_call_only
end

@testset "Many call targets preserve object identity" begin
    scene = Scene(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:leaf_b; scale=:Leaf, parent=:scene),
        Object(:leaf_a; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(ManyCallControllerModel(); name=:controller) |>
                AppliesTo(One(name=:scene)) |>
                Calls(
                    :children => Many(
                        scale=:Leaf,
                        within=SceneScope(),
                        application=:leaf_calls,
                    ),
                ),
            ModelSpec(NestedCallLeafModel(); name=:leaf_calls) |>
                AppliesTo(Many(scale=:Leaf)),
        ),
        environment=(duration=Hour(1),),
    )

    compiled = Advanced.refresh_bindings!(scene)
    call = only(explain_calls(compiled))
    @test call.callee_object_ids == [:leaf_a, :leaf_b]
    @test call.callee_application_ids == [:leaf_calls]

    simulation = run!(scene; outputs=:all)
    controller = only(scene_objects(scene; scale=:Scene)).status
    @test controller.ncalls == 2
    @test controller.total == 2.0
    rows = filter(
        row -> row.application_id == :leaf_calls && row.variable == :value,
        collect_outputs(simulation; sink=nothing),
    )
    @test getproperty.(rows, :object_id) == [:leaf_a, :leaf_b]
    @test getproperty.(rows, :value) == [1.0, 1.0]
end

@testset "manual target cadence contract" begin
    incompatible = Scene(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:leaf; scale=:Leaf, name=:leaf, parent=:scene);
        applications=(
            ModelSpec(ManyCallControllerModel(); name=:controller) |>
                AppliesTo(One(name=:scene)) |>
                Calls(:children => One(name=:leaf, application=:leaf_calls)) |>
                TimeStep(Day(1)),
            ModelSpec(NestedCallLeafModel(); name=:leaf_calls) |>
                AppliesTo(One(name=:leaf)) |>
                TimeStep(Hour(1)),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "incompatible cadence" Advanced.refresh_bindings!(incompatible)

    inherited = Scene(
        Object(:scene; scale=:Scene, name=:scene),
        Object(:leaf; scale=:Leaf, name=:leaf, parent=:scene);
        applications=(
            ModelSpec(ManyCallControllerModel(); name=:controller) |>
                AppliesTo(One(name=:scene)) |>
                Calls(:children => One(name=:leaf, application=:leaf_calls)) |>
                TimeStep(Day(1)),
            ModelSpec(NestedCallLeafModel(); name=:leaf_calls) |>
                AppliesTo(One(name=:leaf)),
        ),
        environment=(duration=Hour(1),),
    )
    @test_nowarn Advanced.refresh_bindings!(inherited)
end
