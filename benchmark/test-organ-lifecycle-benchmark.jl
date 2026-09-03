using MultiScaleTreeGraph
using PlantSimEngine

PlantSimEngine.@process "organ_lifecycle_leaf" verbose = false

struct OrganLifecycleLeafModel <: AbstractOrgan_Lifecycle_LeafModel end

PlantSimEngine.inputs_(::OrganLifecycleLeafModel) = NamedTuple()
PlantSimEngine.outputs_(::OrganLifecycleLeafModel) = (signal=0.0,)

function PlantSimEngine.run!(
    ::OrganLifecycleLeafModel,
    status,
    environment,
    constants=nothing,
    context=nothing,
)
    status.signal += 1.0
    return nothing
end

PlantSimEngine.@process "organ_lifecycle_status_recipe" verbose = false

struct OrganLifecycleStatusRecipeModel <:
       AbstractOrgan_Lifecycle_Status_RecipeModel end

const ORGAN_LIFECYCLE_RECIPE_OUTPUT_NAMES =
    ntuple(index -> Symbol(:recipe_output_, index), 32)
const ORGAN_LIFECYCLE_RECIPE_INPUT_NAMES =
    ntuple(index -> Symbol(:recipe_input_, index), 32)

PlantSimEngine.outputs_(::OrganLifecycleStatusRecipeModel) =
    NamedTuple{ORGAN_LIFECYCLE_RECIPE_OUTPUT_NAMES}(
        ntuple(_ -> 0.0, length(ORGAN_LIFECYCLE_RECIPE_OUTPUT_NAMES)),
    )

PlantSimEngine.inputs_(::OrganLifecycleStatusRecipeModel) =
    NamedTuple{ORGAN_LIFECYCLE_RECIPE_INPUT_NAMES}(
        ntuple(
            _ -> PlantSimEngine.Default(1.0),
            length(ORGAN_LIFECYCLE_RECIPE_INPUT_NAMES),
        ),
    )

function PlantSimEngine.run!(
    ::OrganLifecycleStatusRecipeModel,
    status,
    environment,
    constants=nothing,
    context=nothing,
)
    return nothing
end

_organ_lifecycle_status(node) =
    PlantSimEngine.Status(node=node, signal=0.0)

function setup_organ_topology_benchmark(nobjects::Int)
    nobjects > 0 || throw(ArgumentError("`nobjects` must be positive."))
    root = MultiScaleTreeGraph.Node(
        MultiScaleTreeGraph.NodeMTG("/", :Scene, 1, 0),
    )
    plant = MultiScaleTreeGraph.Node(
        2,
        root,
        MultiScaleTreeGraph.NodeMTG("/", :Plant, 1, 1),
    )
    for index in 1:nobjects
        MultiScaleTreeGraph.Node(
            index + 2,
            plant,
            MultiScaleTreeGraph.NodeMTG("+", :Leaf, index, 2),
        )
    end
    return (
        root=root,
        plant=plant,
        nobjects=nobjects,
        next_node_id=nobjects + 3,
    )
end

Base.@noinline function benchmark_adapt_organ_model(topology)
    return PlantSimEngine.CompositeModel(
        topology.root;
        applications=(
            PlantSimEngine.ModelSpec(
                OrganLifecycleLeafModel();
                name=:organ_lifecycle_leaf,
                on=PlantSimEngine.Many(scale=:Leaf),
            ),
        ),
        status=_organ_lifecycle_status,
    )
end

Base.@noinline function benchmark_adapt_organ_status_recipe_model(topology)
    return PlantSimEngine.CompositeModel(
        topology.root;
        applications=(
            PlantSimEngine.ModelSpec(
                OrganLifecycleStatusRecipeModel();
                name=:organ_lifecycle_status_recipe,
                on=PlantSimEngine.Many(scale=:Leaf),
            ),
        ),
        status=node -> PlantSimEngine.Status(node=node),
    )
end

function setup_organ_lifecycle_benchmark(
    nobjects::Int;
    start_simulation::Bool=false,
)
    topology = setup_organ_topology_benchmark(nobjects)
    model = benchmark_adapt_organ_model(topology)
    simulation = if start_simulation
        PlantSimEngine.run!(model; steps=1, outputs=:none)
    else
        compiled = PlantSimEngine.Advanced.refresh_bindings!(model)
        PlantSimEngine.Advanced.refresh_environment_bindings!(
            model,
            compiled,
        )
        nothing
    end
    return merge(topology, (; model, simulation))
end

function setup_organ_refresh_benchmark(nobjects::Int)
    data = setup_organ_lifecycle_benchmark(nobjects)
    status = benchmark_add_organ!(data)
    return merge(data, (; status))
end

function setup_organ_status_recipe_refresh_benchmark(nobjects::Int)
    topology = setup_organ_topology_benchmark(nobjects)
    model = benchmark_adapt_organ_status_recipe_model(topology)
    PlantSimEngine.Advanced.refresh_bindings!(model)
    data = merge(topology, (; model))
    benchmark_add_status_recipe_organ!(data)
    return data
end

Base.@noinline function benchmark_add_organ!(data)
    return PlantSimEngine.add_organ!(
        data.plant,
        data.model,
        "+",
        :Leaf,
        2;
        index=data.nobjects + 1,
        initial_status=(signal=1.0,),
    )
end

Base.@noinline function benchmark_add_status_recipe_organ!(data)
    return PlantSimEngine.add_organ!(
        data.plant,
        data.model,
        "+",
        :Leaf,
        2;
        index=data.nobjects + 1,
    )
end

Base.@noinline function benchmark_refresh_after_add!(data)
    PlantSimEngine.Advanced.refresh_bindings!(data.model)
    return data.model
end

Base.@noinline function benchmark_status_recipe_refresh_after_add!(data)
    PlantSimEngine.Advanced.refresh_bindings!(data.model)
    return data.model
end

Base.@noinline function benchmark_add_and_refresh!(data)
    status = benchmark_add_organ!(data)
    PlantSimEngine.Advanced.refresh_bindings!(data.model)
    return status
end

Base.@noinline function benchmark_add_and_continue!(data)
    status = benchmark_add_organ!(data)
    PlantSimEngine.continue!(data.simulation)
    return status
end
