# Writing a multiscale simulation

TODO change Toy To Example ?

This section iteratively walks you through building a multi-scale simulation. 

The actual plant being simulated, as well as some of the ad hoc processes, mostly have no physical meaning and are very much ad hoc (which is why they aren't part of the TODO examples folder). Similarly, some of the parameter values are pulled out of thin air, and have no ties to research papers or data.

The main purpose here is to showcase PlantSimEngine's multi-scale features and how to structure your models, not accuracy, realism or performance.

You can find the full script for this simulation in TODO

## A basic growing plant

At minimul, to simulate some kind of fake growth, we need :

- A MultiScale Tree Graph representing the plant
- Some way of adding organs to the plant
- Some kind of temporality to this dynamic

Let's have some concept of 'leaves' that capture the (carbon) resource necessary for organ growth, and let's have the organ emergence happen at the 'internode' level, to illustrate multiple organs with different behavior.

We'll make the assumption the internodes make use of carbon from a common pool. We'll also make use of thermal time as a growth delay factor.

One way of modeling this approach translates into several scales and models : 

- Scene scale, for thermal time. The `ToyDegreeDaysCumulModel()` from the examples folder provides thermal time from temperature data *TODO
- Plant scale, where we'll define the carbon pool
- Internode scale, which draws from the pool to create new organs
- Leaf scale, which captures carbon

Let's also add a very artificial limiting factor : if the total leaf surface area is above a threshold no new organs are created.

We can expect the simulation mapping to look like a more complex version of the following : 

```julia
mapping = Dict(
"Scene" => ToyDegreeDaysCumulModel(),
"Plant" => ToyStockComputationModel(),
"Internode" => ToyCustomInternodeEmergence(),
"Leaf" => ToyLeafCarbonCaptureModel(),
)
```

Some of the models will need to gather variables from scales other than their own, meaning they will need to be converted into MultiScaleModels.

## Implementation

### Carbon Capture

Let's start with the simplest model. Leaves continuously capture some constant amount of carbon every timestep. No inputs are required.

```julia
PlantSimEngine.@process "leaf_carbon_capture" verbose = false

struct ToyLeafCarbonCaptureModel<: AbstractLeaf_Carbon_CaptureModel end

function PlantSimEngine.inputs_(::ToyLeafCarbonCaptureModel)
    NamedTuple() # No inputs
end

function PlantSimEngine.outputs_(::ToyLeafCarbonCaptureModel)
    (carbon_captured=0.0,)
end

function PlantSimEngine.run!(::ToyLeafCarbonCaptureModel, models, status, meteo, constants, extra)   
    status.carbon_captured = 40
end
```

### Resource storage

The model storing resources for the whole plant needs a couple of inputs : the amount of carbon captured by the leaves, as well as the amount consumed by the creation of new organs. It outputs the current stock.

TODO

```julia
PlantSimEngine.@process "resource_stock_computation" verbose = false

struct ToyStockComputationModel <: AbstractResource_Stock_ComputationModel
end

PlantSimEngine.inputs_(::ToyStockComputationModel) = 
(carbon_captured=0.0,carbon_organ_creation_consumed=0.0)

PlantSimEngine.outputs_(::ToyStockComputationModel) = (carbon_stock=-Inf,)

function PlantSimEngine.run!(m::ToyStockComputationModel, models, status, meteo, constants=nothing, extra=nothing)
    status.carbon_stock += sum(status.carbon_captured) - sum(status.carbon_organ_creation_consumed)
end
```

### Organ creation

This model is a modified version of the `ToyInternodeEmergence()` model found in the examples folder TODO. An internode produces two leaves and a new internode.

Let's first define a helper function that iterates across a Multiscale Tree Graph and returns the number of leaves :

```julia
function get_n_leaves(node::MultiScaleTreeGraph.Node)
    root = MultiScaleTreeGraph.get_root(node)
    nleaves = length(MultiScaleTreeGraph.traverse(root, x->1, symbol="Leaf"))
    return nleaves
end
```

Now that we have that, let's define a few parameters to the model. It requires :
- a thermal time emergence threshold
- a carbon cost for organ creation

We'll also add a couple of other parameters, which could go elsewhere :
- the surface area of a leaf (no variation, no growth stages)
- the max leaf surface area beyond which organ creation stops

```julia
PlantSimEngine.@process "organ_emergence" verbose = false

struct ToyCustomInternodeEmergence <: AbstractOrgan_EmergenceModel
    TT_emergence::Float64
    carbon_internode_creation_cost::Float64
    leaf_surface_area::Float64
    leaves_max_surface_area::Float64
end

```

And give them some default values : 

```julia
ToyCustomInternodeEmergence(;TT_emergence=300.0, carbon_internode_creation_cost=200.0, leaf_surface_area=3.0, leaves_max_surface_area=100.0) = ToyCustomInternodeEmergence(TT_emergence, carbon_internode_creation_cost, leaf_surface_area, leaves_max_surface_area)
```

Our internode model requires thermal time, and the amount of available carbon, and outputs the amount of carbon consumed, as well as the last thermal time where emergence happened (this is useful when new organs can be produced multiple times, which won't be the case here).

```julia
PlantSimEngine.inputs_(m::ToyCustomInternodeEmergence) = (TT_cu=0.0, carbon_stock=0.0)
PlantSimEngine.outputs_(m::ToyCustomInternodeEmergence) = (TT_cu_emergence=0.0, carbon_organ_creation_consumed=0.0)
```
Finally, the `run!` function checks that conditions are met for new organ creation :
- thermal time threshold exceeded
- total leaf surface area not above limit
- carbon available
- no organs already created by that internode

and then updates the MTG.

```julia
function PlantSimEngine.run!(m::ToyCustomInternodeEmergence, models, status, meteo, constants=nothing, sim_object=nothing)

    leaves_surface_area = m.leaf_surface * get_n_leaves(status.node)
    status.carbon_organ_creation_consumed = 0.0

    if leaves_surface_area > m.leaves_max_surface_area
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

## Updated mapping

We can now define the final mapping for this simulation. 

The carbon capture and thermal time models don't need to be changed from the earlier version. 
The organ creation model at the "Internode" scale needs the carbon stock from the "Plant" scale, as well as thermal time from the "Scene" scale.
The resource storing model at the "Plant" scale needs the carbon captured by **every** leaf, and the carbon consumed by **every** internode that created new organs this timestep. This requires mapping vector variables :

```julia
 mapping=[
            :carbon_captured=>["Leaf"],
            :carbon_organ_creation_consumed=>["Internode"]
        ],
```
as opposed to the single-valued carbon stock mapped variable : 

```julia
 mapping=[:TT_cu => "Scene",
            PreviousTimeStep(:carbon_stock)=>"Plant"],
```

And of course, some variables need to be initialized in the status

```julia
mapping = Dict(
"Scene" => ToyDegreeDaysCumulModel(),
"Plant" => (
    MultiScaleModel(
        model=ToyStockComputationModel(),          
        mapping=[
            :carbon_captured=>["Leaf"],
            :carbon_organ_creation_consumed=>["Internode"]
        ],
        ),
        Status(carbon_stock = 0.0)
    ),
"Internode" => (        
        MultiScaleModel(
            model=ToyCustomInternodeEmergence(),#TT_emergence=20.0),
            mapping=[:TT_cu => "Scene",
            PreviousTimeStep(:carbon_stock)=>"Plant"],
        ),        
        Status(carbon_organ_creation_consumed=0.0),
    ),
"Leaf" => ToyLeafCarbonCaptureModel(),
)
```
### Running a simulation 

We only need an MTG, and some weather data, and then we'll be set. Let's create a simple MTG : 

```julia
 mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0))   
    plant = MultiScaleTreeGraph.Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))
    
    internode1 = MultiScaleTreeGraph.Node(plant, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    MultiScaleTreeGraph.Node(internode1, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
    MultiScaleTreeGraph.Node(internode1, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))

    internode2 = MultiScaleTreeGraph.Node(internode1, MultiScaleTreeGraph.NodeMTG("<", "Internode", 1, 2))
    MultiScaleTreeGraph.Node(internode2, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
    MultiScaleTreeGraph.Node(internode2, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
```

Import some weather data : 

```julia
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
```

And we're good to go ! 

```julia
outs = run!(mtg, mapping, meteo_day)
```

And that's it. If you query or display the MTG after simulation, you'll see it expanded and grew multiple internodes and leaves :

```julia
mtg
get_n_leaves(mtg)
```

Feel free to tinker with the parameters and see when things break down, to get a feel for the simulation.

Of course, this is a very crude and unrealistic simulation, with many dubious assumptions and parameters. But significantly more complex modelling is possible using the same approach : XPalm runs using a few dozen models spread out over nine scales.

