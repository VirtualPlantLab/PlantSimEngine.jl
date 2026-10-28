using Dates

PlantSimEngine.@process "organ_creation_allocation_probe" verbose = false

struct OrganCreationAllocationProbeModel <: AbstractOrgan_Creation_Allocation_ProbeModel
    increment::Float64
end

PlantSimEngine.inputs_(::OrganCreationAllocationProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::OrganCreationAllocationProbeModel) = (signal=0.0,)

function PlantSimEngine.run!(
    model::OrganCreationAllocationProbeModel,
    status,
    environment,
    constants,
    context,
)
    status.signal += model.increment
    return nothing
end

function _organ_existing_index_allocations(index, id)
    PlantSimEngine._push_index!(index, :Leaf, id)
    return @allocated for _ in 1:32
        PlantSimEngine._push_index!(index, :Leaf, id)
    end
end

function _organ_attribute_validation_allocations(attributes)
    PlantSimEngine._validate_organ_attributes(attributes)
    return @allocated PlantSimEngine._validate_organ_attributes(attributes)
end

@testset "organ registration reuses populated index buckets" begin
    id = ObjectId(7)
    index = Dict{Symbol,Set{ObjectId}}(:Leaf => Set{ObjectId}([id]))
    leaf_ids = index[:Leaf]
    # An ObjectId held through an abstract element type may still be boxed. The
    # budget excludes recreating a Set (and its backing table) per lookup.
    @test _organ_existing_index_allocations(index, id) <= 32 * 32
    @test index[:Leaf] === leaf_ids
    @test leaf_ids == Set([id])

    PlantSimEngine._push_index!(index, :Leaf, ObjectId(8))
    @test leaf_ids == Set([id, ObjectId(8)])
    PlantSimEngine._push_index!(index, :Bud, ObjectId(9))
    @test index[:Bud] == Set([ObjectId(9)])
    PlantSimEngine._push_index!(index, nothing, id)
    @test Set(keys(index)) == Set([:Leaf, :Bud])
end

@testset "organ attribute validation does not materialize scientific values" begin
    large_value = ntuple(Float64, 256)
    attributes = (index=1, scientific_value=large_value, label="leaf")
    status = Status(attributes)
    @test _organ_attribute_validation_allocations(attributes) == 0
    @test _organ_attribute_validation_allocations(status) == 0

    for source in (
        attributes,
        status,
        Dict{String,Any}("area" => 2.0),
        pairs((area=2.0,)),
        nothing,
    )
        @test PlantSimEngine._validate_organ_attributes(source) === source
    end
    for source in (
        (plantsimengine_status=nothing,),
        Status(plantsimengine_status=nothing),
        Dict("plantsimengine_status" => nothing),
        pairs((plantsimengine_status=nothing,)),
    )
        exception = try
            PlantSimEngine._validate_organ_attributes(source)
            nothing
        catch caught
            caught
        end
        @test exception isa ErrorException
        @test occursin("runtime state, not an organ attribute", sprint(showerror, exception))
    end
end

@testset "organ insertion preserves ids, status identity, and lifecycle snapshots" begin
    root = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant = Node(root, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    model = CompositeModel(root)
    @test isempty(model.instances)
    @test isnothing(PlantSimEngine._instance_for_object(model, ObjectId(2)))

    initial_ids = object_ids(model)
    initial_max_id = model.source_adapter.max_node_id[]
    @test_throws ErrorException add_organ!(
        plant, model, :+, :Leaf, 2;
        attributes=(plantsimengine_status=nothing,),
        use_status_adapter=false,
    )
    @test object_ids(model) == initial_ids
    @test model.source_adapter.max_node_id[] == initial_max_id
    @test isempty(MultiScaleTreeGraph.children(plant))

    explicit = add_organ!(
        plant, model, :+, :Leaf, 2;
        id=40,
        attributes=(area=2.0,),
        initial_status=(area=3.0,),
        use_status_adapter=false,
    )
    automatic = add_organ!(
        plant, model, :+, :Leaf, 2;
        use_status_adapter=false,
    )
    @test object_id(model, explicit) == ObjectId(40)
    @test object_id(model, automatic) == ObjectId(41)
    @test explicit.area == 3.0
    @test explicit.node[:area] == 2.0
    @test model_status(model, explicit.node) === explicit
    @test source_node(model, explicit) === explicit.node
    @test !haskey(MultiScaleTreeGraph.node_attributes(explicit.node), :plantsimengine_status)
    @test last(model.lifecycle_delta.added).ancestors == (
        ObjectId(1), ObjectId(2), ObjectId(41),
    )
    @test PlantSimEngine._lifecycle_object_snapshot(model, Object(:unregistered)).ancestors == ()

    before_duplicate = object_ids(model)
    @test_throws ErrorException add_organ!(plant, model, :+, :Leaf, 2; id=40)
    @test object_ids(model) == before_duplicate
    @test length(MultiScaleTreeGraph.children(plant)) == 2

    remove_object!(model, ObjectId(40))
    @test_throws ArgumentError object_id(model, explicit)
    @test_throws ArgumentError object_id(model, explicit.node)
    @test model_status(model, automatic.node) === automatic
    @test only(model.lifecycle_delta.removed).ancestors == (
        ObjectId(1), ObjectId(2), ObjectId(40),
    )
end

@testset "new organs retain instance labels and scoped application membership" begin
    root = Node(MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0))
    plant_a = Node(root, MultiScaleTreeGraph.NodeMTG("+", :Plant, 1, 1))
    plant_b = Node(root, MultiScaleTreeGraph.NodeMTG("+", :Plant, 2, 1))
    template(increment) = CompositeModelTemplate((
        ModelSpec(
            OrganCreationAllocationProbeModel(increment);
            name=:allocation_probe,
            on=Many(scale=:Leaf),
        ),
    ); kind=:tree, species=:probe_species)
    model = CompositeModel(
        root;
        instances=(
            ObjectInstance(:first, template(1.0); root=MultiScaleTreeGraph.node_id(plant_a)),
            ObjectInstance(:second, template(10.0); root=MultiScaleTreeGraph.node_id(plant_b)),
        ),
        environment=(duration=Hour(1),),
    )
    simulation = run!(model; steps=0, outputs=:none)
    first = add_organ!(plant_a, model, :+, :Leaf, 2; use_status_adapter=false)
    second = add_organ!(plant_b, model, :+, :Leaf, 2; use_status_adapter=false)
    sibling = add_organ!(plant_a, model, :+, :Leaf, 2; use_status_adapter=false)
    first_id = object_id(model, first)
    second_id = object_id(model, second)
    sibling_id = object_id(model, sibling)
    @test model_object(model, first).kind == :tree
    @test model_object(model, second).species == :probe_species
    @test PlantSimEngine._instance_for_object(model, sibling_id).name == :first
    continue!(simulation)
    @test model_status(model, first.node).signal == 1.0
    @test model_status(model, sibling.node).signal == 1.0
    @test model_status(model, second.node).signal == 10.0

    compiled = simulation.compiled
    @test Set(compiled.applications_by_id[:first__allocation_probe].target_ids) ==
          Set([first_id, sibling_id])
    @test compiled.applications_by_id[:second__allocation_probe].target_ids ==
          [second_id]
    remove_object!(model, first_id)
    continue!(simulation)
    @test model_status(model, sibling.node).signal == 2.0
    @test model_status(model, second.node).signal == 20.0
    @test simulation.compiled.applications_by_id[:first__allocation_probe].target_ids ==
          [sibling_id]
end
