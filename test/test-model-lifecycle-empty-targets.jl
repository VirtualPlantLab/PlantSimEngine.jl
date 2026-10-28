using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "lifecycle_empty_targets" verbose = false
struct LifecycleEmptyTargetsModel <: AbstractLifecycle_Empty_TargetsModel end
PlantSimEngine.inputs_(::LifecycleEmptyTargetsModel) = NamedTuple()
PlantSimEngine.outputs_(::LifecycleEmptyTargetsModel) = (seen=0.0,)
PlantSimEngine.environment_inputs_(::LifecycleEmptyTargetsModel) = (T=0.0,)
function PlantSimEngine.run!(::LifecycleEmptyTargetsModel, status, environment, constants, context)
    status.seen = environment.T
    return nothing
end

@testset "Unscoped templates ignore topology depth" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:leaf; scale=:Leaf, parent=:plant);
        applications=(ModelSpec(LifecycleEmptyTargetsModel(); name=:leaf, on=Many(scale=:Leaf)),),
        environment=(T=21.0, duration=Hour(1)),
    )
    simulation = run!(model; steps=0, outputs=:none)
    original_binding = simulation.environment_bindings.by_target[(:leaf, ObjectId(:leaf))]
    index = simulation.compiled.scenario_plan.application_target_candidates
    original_key = PlantSimEngine._application_target_template_key(index, model, ObjectId(:leaf))
    parent = :plant
    for depth in 1:16
        id = Symbol(:branch_, depth)
        register_object!(model, Object(id; scale=:Axis, parent=parent))
        parent = id
    end
    register_object!(model, Object(:deep_leaf; scale=:Leaf, parent=parent))
    continue!(simulation; steps=1)
    @test PlantSimEngine._application_target_template_key(index, model, ObjectId(:deep_leaf)) == original_key
    @test simulation.compiled.applications_by_id[:leaf].target_ids == ObjectId.([:deep_leaf, :leaf])
    @test Set(keys(simulation.environment_bindings.by_target)) ==
          Set(((:leaf, ObjectId(:leaf)), (:leaf, ObjectId(:deep_leaf))))
    @test simulation.environment_bindings.by_target[(:leaf, ObjectId(:leaf))] === original_binding
    @test model_object(model, :leaf).status.seen == 21.0
    @test model_object(model, :deep_leaf).status.seen == 21.0

    # Graph-only removals must leave the surviving leaf binding intact.
    register_object!(model, Object(:unused_axis; scale=:Axis, parent=:plant))
    continue!(simulation; steps=0)
    remove_object!(model, :unused_axis)
    continue!(simulation; steps=0)
    @test simulation.environment_bindings.by_target[(:leaf, ObjectId(:leaf))] === original_binding
    @test !haskey(simulation.environment_bindings.targets_by_object, ObjectId(:unused_axis))
end

@testset "Scoped targets refresh environment membership after reparenting and removal" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_a; scale=:Plant, parent=:scene, geometry=(cell=:sun,)),
        Object(:plant_b; scale=:Plant, parent=:scene, geometry=(cell=:shade,)),
        Object(:leaf; scale=:Leaf, parent=:plant_a);
        applications=(
            ModelSpec(LifecycleEmptyTargetsModel(); name=:a, on=Many(scale=:Leaf, within=Scope(:plant_a))),
            ModelSpec(LifecycleEmptyTargetsModel(); name=:b, on=Many(scale=:Leaf, within=Scope(:plant_b))),
        ),
        environment=(T=23.0, duration=Hour(1)),
    )
    simulation = run!(model; steps=0, outputs=:none)
    index = simulation.compiled.scenario_plan.application_target_candidates
    old_key = PlantSimEngine._application_target_template_key(index, model, ObjectId(:leaf))
    @test Set(keys(simulation.environment_bindings.by_target)) == Set(((:a, ObjectId(:leaf)),))
    @test only(simulation.environment_bindings.bindings).geometry_source_object_id == ObjectId(:plant_a)

    reparent_object!(model, :leaf, :plant_b)
    continue!(simulation; steps=1)
    @test PlantSimEngine._application_target_template_key(index, model, ObjectId(:leaf)) != old_key
    @test isempty(simulation.compiled.applications_by_id[:a].target_ids)
    @test simulation.compiled.applications_by_id[:b].target_ids == [ObjectId(:leaf)]
    @test Set(keys(simulation.environment_bindings.by_target)) == Set(((:b, ObjectId(:leaf)),))
    @test only(simulation.environment_bindings.bindings).geometry_source_object_id == ObjectId(:plant_b)
    @test model_object(model, :leaf).status.seen == 23.0

    # A removed target has no current applications, but its old environment
    # bindings still need removal from every cache and position index.
    remove_object!(model, :leaf)
    continue!(simulation; steps=0)
    @test isempty(simulation.compiled.applications_by_id[:b].target_ids)
    @test isempty(simulation.environment_bindings.bindings)
    @test isempty(simulation.environment_bindings.by_target)
    @test isempty(simulation.environment_bindings.positions_by_target)
    @test isempty(simulation.environment_bindings.targets_by_object)
end
