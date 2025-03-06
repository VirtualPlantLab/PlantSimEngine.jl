# Expanding on the multiscale simulation

Let's build on the previous example and add some other organ growth, as well as some very mild coupling between the two.

You can find the full script for this simulation in the [ToyMultiScalePlantModel](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/ToyMultiScalePlantModel/ToyPlantSimulation2.jl) subfolder of the examples folder.

## Adding roots to our plant

We'll add a root that extracts water and adds it to the stock. Initial water stocks are low, so root growth is prioritized, then the plant also grows leaves and a new internode like it did before. Roots only grow up to a certain point, and don't branch.

This leads to adding a new scale, "Root" to the mapping, as well as two more models, one for water absorption, the other for root growth. Other models are updated here and there to account for water. The carbon capture model remains unchanged.

## Root models

### Water absorption

Let's implement a very fake model of root water absorption. It'll capture the amount of precipitation in the weather data multiplied by some assimilation factor.

```julia
PlantSimEngine.@process "water_absorption" verbose = false

struct ToyWaterAbsorptionModel <: AbstractWater_AbsorptionModel
end

PlantSimEngine.inputs_(::ToyWaterAbsorptionModel) = (root_water_assimilation=1.0,)
PlantSimEngine.outputs_(::ToyWaterAbsorptionModel) = (water_absorbed=0.0,)

function PlantSimEngine.run!(m::ToyWaterAbsorptionModel, models, status, meteo, constants=nothing, extra=nothing)
    status.water_absorbed = meteo.Precipitations * status.root_water_assimilation
end
```

### Root growth

The root growth model is similar to the internode growth one : it checks for a water threshold and that there is enough carbon, and adds a new organ to the MTG if the maximum length hasn't been reached.

It also makes use of a couple of helper functions to find the end root and compute root length : 

```julia
function get_root_end_node(node::MultiScaleTreeGraph.Node)
    root = MultiScaleTreeGraph.get_root(node)
    return MultiScaleTreeGraph.traverse(root, x->x, symbol="Root", filter_fun = MultiScaleTreeGraph.isleaf)
end

function get_roots_count(node::MultiScaleTreeGraph.Node)
    root = MultiScaleTreeGraph.get_root(node)
    return length(MultiScaleTreeGraph.traverse(root, x->x, symbol="Root"))
end

PlantSimEngine.@process "root_growth" verbose = false

struct ToyRootGrowthModel <: AbstractRoot_GrowthModel
    water_threshold::Float64
    carbon_root_creation_cost::Float64
    root_max_len::Int
end

PlantSimEngine.inputs_(::ToyRootGrowthModel) = (water_stock=0.0,carbon_stock=0.0,)
PlantSimEngine.outputs_(::ToyRootGrowthModel) = (carbon_root_creation_consumed=0.0,)

function PlantSimEngine.run!(m::ToyRootGrowthModel, models, status, meteo, constants=nothing, extra=nothing)
    if status.water_stock < m.water_threshold && status.carbon_stock > m.carbon_root_creation_cost
        
        root_end = get_root_end_node(status.node)
        
        if length(root_end) != 1 
            throw(AssertionError("Couldn't find MTG leaf node with symbol \"Root\""))
        end
        root_len = get_roots_count(root_end[1])
        if root_len < m.root_max_len
            st = add_organ!(root_end[1], extra, "<", "Root", 2, index=1)
            status.carbon_root_creation_consumed = m.carbon_root_creation_cost
        end
    else
        status.carbon_root_creation_consumed = 0.0
    end
end
```

## Updating other models to account for water

### Resource storage

Water absorbed must now be accumulated, and root carbon creation costs taken into account.

```julia
PlantSimEngine.@process "resource_stock_computation" verbose = false

struct ToyStockComputationModel <: AbstractResource_Stock_ComputationModel
end

PlantSimEngine.inputs_(::ToyStockComputationModel) = 
(water_absorbed=0.0,carbon_captured=0.0,carbon_organ_creation_consumed=0.0,carbon_root_creation_consumed=0.0)

PlantSimEngine.outputs_(::ToyStockComputationModel) = (water_stock=-Inf,carbon_stock=-Inf)

function PlantSimEngine.run!(m::ToyStockComputationModel, models, status, meteo, constants=nothing, extra=nothing)
    status.water_stock += sum(status.water_absorbed)
    status.carbon_stock += sum(status.carbon_captured) - sum(status.carbon_organ_creation_consumed) - sum(status.carbon_root_creation_consumed)
end
```

### Internode creation

The minor change is that new organs are now created only if the water stock is above a given threshold.

```julia
struct ToyCustomInternodeEmergence <: AbstractOrgan_EmergenceModel
    TT_emergence::Float64
    carbon_internode_creation_cost::Float64
    leaf_surface_area::Float64
    leaves_max_surface_area::Float64
    water_leaf_threshold::Float64
end

ToyCustomInternodeEmergence(;TT_emergence=300.0, carbon_internode_creation_cost=200.0, leaf_surface_area=3.0,leaves_max_surface_area=100.0,
water_leaf_threshold=30.0) = ToyCustomInternodeEmergence(TT_emergence, carbon_internode_creation_cost, leaf_surface_area, leaves_max_surface_area, water_leaf_threshold)

PlantSimEngine.inputs_(m::ToyCustomInternodeEmergence) = (TT_cu=0.0,water_stock=0.0, carbon_stock=0.0)
PlantSimEngine.outputs_(m::ToyCustomInternodeEmergence) = (TT_cu_emergence=0.0, carbon_organ_creation_consumed=0.0)

function PlantSimEngine.run!(m::ToyCustomInternodeEmergence, models, status, meteo, constants=nothing, sim_object=nothing)

    leaves_surface_area = m.leaf_surface_area * get_n_leaves(status.node)
    status.carbon_organ_creation_consumed = 0.0

    if leaves_surface_area > m.leaves_max_surface_area
        return nothing
    end
    
    # if water levels are low, prioritise roots
    if status.water_stock < m.water_leaf_threshold
        return nothing
    end

    # if not enough carbon, no organ creation
    if status.carbon_stock < m.carbon_internode_creation_cost
        return nothing
    end
  
    if length(MultiScaleTreeGraph.children(status.node)) == 2 && 
        status.TT_cu - status.TT_cu_emergence >= m.TT_emergence            
        status_new_internode = add_organ!(status.node, sim_object, "<", "Internode", 2, index=1)
        add_organ!(status_new_internode.node, sim_object, "+", "Leaf", 2, index=1)
        add_organ!(status_new_internode.node, sim_object, "+", "Leaf", 2, index=1)

        status_new_internode.TT_cu_emergence = m.TT_emergence - status.TT_cu
        status.carbon_organ_creation_consumed = m.carbon_internode_creation_cost
    end

    return nothing
end
```

## Updating the mapping

The resource storage and internode emergence models now need a couple of extra water-related mapped variables. 
The "Root" organ is added to the mapping with its own models. New parameters need to be initialized.

```julia
mapping = Dict(
"Scene" => ToyDegreeDaysCumulModel(),
"Plant" => (
    MultiScaleModel(
        model=ToyStockComputationModel(),          
        mapped_variables=[
            :carbon_captured=>["Leaf"],
            :water_absorbed=>["Root"],
            :carbon_root_creation_consumed=>["Root"],
            :carbon_organ_creation_consumed=>["Internode"]

        ],
        ),
        Status(water_stock = 0.0, carbon_stock = 0.0)
    ),
"Internode" => (        
        MultiScaleModel(
            model=ToyCustomInternodeEmergence(),#TT_emergence=20.0),
            mapped_variables=[:TT_cu => "Scene",
            PreviousTimeStep(:water_stock)=>"Plant",
            PreviousTimeStep(:carbon_stock)=>"Plant"],
        ),        
        Status(carbon_organ_creation_consumed=0.0),
    ),
"Root" => ( MultiScaleModel(
            model=ToyRootGrowthModel(10.0, 50.0, 10),
            mapped_variables=[PreviousTimeStep(:carbon_stock)=>"Plant",
            PreviousTimeStep(:water_stock)=>"Plant"],
        ),       
            ToyWaterAbsorptionModel(),
            Status(carbon_root_creation_consumed=0.0, root_water_assimilation=1.0),
            ),
"Leaf" => ( ToyLeafCarbonCaptureModel(),),
)
```

## Running the simulation

Running this new simulation is almost the same as before. The weather data is unchanged, but a new "Root" node was added to the MTG.

```julia
mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0))   
    plant = MultiScaleTreeGraph.Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))
    
    internode1 = MultiScaleTreeGraph.Node(plant, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    MultiScaleTreeGraph.Node(internode1, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
    MultiScaleTreeGraph.Node(internode1, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))

    internode2 = MultiScaleTreeGraph.Node(internode1, MultiScaleTreeGraph.NodeMTG("<", "Internode", 1, 2))
    MultiScaleTreeGraph.Node(internode2, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
    MultiScaleTreeGraph.Node(internode2, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))

    plant_root_start = MultiScaleTreeGraph.Node(
        plant, 
        MultiScaleTreeGraph.NodeMTG("+", "Root", 1, 3), 
    )

meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
    
outs = run!(mtg, mapping, meteo_day)
```

And that's it ! 

...Or is it ?

If you inspect the code and output data closely, you may notice some distinctive problems with the way the simulation runs... Some things aren't quite right. If you wish to know more, onwards to the next chapter: [Fixing bugs in the plant simulation](@ref)