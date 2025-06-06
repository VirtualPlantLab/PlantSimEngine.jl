# Writing a multiscale simulation

This three-part subsection walks you through building a multi-scale simulation from scratch. It is meant as an illustration of the iterative process you might go through when building and slowly tuning a Functional-Structural Plant Model, where previous multi-scale examples focused more on the API syntax.

You can find the full script for the first part's toy simulation in the [ToyMultiScalePlantModel](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/ToyMultiScalePlantModel/ToyPlantSimulation1.jl) subfolder of the examples folder.

```@contents
Pages = ["multiscale_example_1.md"]
Depth = 3
```

## Disclaimer

The actual plant being created, as well as some of the custom models, have no real physical meaning and are very much ad hoc (which is why most of them aren't standalone in the examples folder). Similarly, some of the parameter values are pulled out of thin air, and have no ties to research papers or data.

The main purpose here is to showcase PlantSimEngine's multi-scale features and how to structure your models, not accuracy, realism or performance.

## Initial setup

We'll need to make use of a few packages, as usual, after adding them to our Julia environment:

```@example usepkg
using PlantSimEngine
using PlantSimEngine.Examples # to import the ToyDegreeDaysCumulModel model
using PlantMeteo
using MultiScaleTreeGraph # multi-scale
using CSV, DataFrames # used to import the example weather data
```

## A basic growing plant

At minimum, to simulate some kind of fake growth, we need :

- A Multi-scale Tree Graph representing the plant
- Some way of adding organs to the plant
- Some kind of temporality to spread this growth over multiple timesteps

Let's have some concept of 'leaves' that capture the (carbon) resource necessary for organ growth, and let's have the organ emergence happen at the 'internode' level, to illustrate multiple organs with different behavior.

We'll make the assumption that the internodes make use of carbon from a common pool. We'll also make use of thermal time as a growth delay factor.

To sum up, we have: 
- a MTG with growing internodes and leaves
- Individual leaves that capture carbon fed into a common pool
- Internodes which take from that pool to create new organs, with a thermal time constraint.

One way of modeling this approach translates into several scales and models: 

- a Scene scale, for thermal time. The [`ToyDegreeDaysCumulModel`](@ref) from the [examples folder](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/ToyDegreeDays.jl) provides thermal time from temperature data 
- a Plant scale, where we'll define the carbon pool
- an Internode scale, which draws from the pool to create new organs
- a Leaf scale, which captures carbon

Let's also add a very artificial limiting factor: if the total leaf surface area is above a threshold no new organs are created.

We can expect the simulation mapping to look like a more complex version of the following: 

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

Let's start with the simplest model. Our fake leaves will continuously capture some constant amount of carbon every timestep. No inputs or parameters are required.

```@example usepkg
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

The model storing resources for the whole plant needs a couple of inputs: the amount of carbon captured by the leaves, as well as the amount consumed by the creation of new organs. It outputs the current stock.

```@example usepkg
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

This model is a modified version of the ToyInternodeEmergence model found [in the examples folder](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/ToyInternodeEmergence.jl). An internode produces two leaves and a new internode.

Let's first define a helper function that iterates across a Multiscale Tree Graph and returns the number of leaves :

```@example usepkg
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

```@example usepkg
PlantSimEngine.@process "organ_emergence" verbose = false

struct ToyCustomInternodeEmergence{T} <: AbstractOrgan_EmergenceModel
    TT_emergence::T
    carbon_internode_creation_cost::T
    leaf_surface_area::T
    leaves_max_surface_area::T
end
```

!!! note 
    We make use of parametric types instead of the intuitive Float64 for flexibility. See [Parametric types](@ref) for a more in-depth explanation

And give them some default values : 

```@example usepkg
ToyCustomInternodeEmergence(;TT_emergence=300.0, carbon_internode_creation_cost=200.0, leaf_surface_area=3.0, leaves_max_surface_area=100.0) = ToyCustomInternodeEmergence(TT_emergence, carbon_internode_creation_cost, leaf_surface_area, leaves_max_surface_area)
```

Our internode model requires thermal time, and the amount of available carbon, and outputs the amount of carbon consumed, as well as the last thermal time where emergence happened (this is useful when new organs can be produced multiple times, which won't be the case here).

```@example usepkg
PlantSimEngine.inputs_(m::ToyCustomInternodeEmergence) = (TT_cu=0.0, carbon_stock=0.0)
PlantSimEngine.outputs_(m::ToyCustomInternodeEmergence) = (TT_cu_emergence=0.0, carbon_organ_creation_consumed=0.0)
```
Finally, the [`run!`](@ref) function checks that conditions are met for new organ creation :
- thermal time threshold exceeded
- total leaf surface area not above limit
- carbon available
- no organs already created by that internode

and then updates the MTG.

```@example usepkg
function PlantSimEngine.run!(m::ToyCustomInternodeEmergence, models, status, meteo, constants=nothing, sim_object=nothing)

    leaves_surface_area = m.leaf_surface_area * get_n_leaves(status.node)
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

### Updated mapping

We can now define the final mapping for this simulation. 

The carbon capture and thermal time models don't need to be changed from the earlier version. 
The organ creation model at the "Internode" scale needs the carbon stock from the "Plant" scale, as well as thermal time from the "Scene" scale.
The resource storing model at the "Plant" scale needs the carbon captured by **every** leaf, and the carbon consumed by **every** internode that created new organs this timestep. This requires mapping vector variables :

```julia
 mapped_variables=[
            :carbon_captured=>["Leaf"],
            :carbon_organ_creation_consumed=>["Internode"]
        ],
```
as opposed to the single-valued carbon stock mapped variable : 

```julia
 mapped_variables=[:TT_cu => "Scene",
            PreviousTimeStep(:carbon_stock)=>"Plant"],
```

And of course, some variables need to be initialized in the status:

```@example usepkg
mapping = Dict(
"Scene" => ToyDegreeDaysCumulModel(),
"Plant" => (
    MultiScaleModel(
        model=ToyStockComputationModel(),          
        mapped_variables=[
            :carbon_captured=>["Leaf"],
            :carbon_organ_creation_consumed=>["Internode"]
        ],
        ),
        Status(carbon_stock = 0.0)
    ),
"Internode" => (        
        MultiScaleModel(
            model=ToyCustomInternodeEmergence(),#TT_emergence=20.0),
            mapped_variables=[:TT_cu => "Scene",
            PreviousTimeStep(:carbon_stock)=>"Plant"],
        ),        
        Status(carbon_organ_creation_consumed=0.0),
    ),
"Leaf" => ToyLeafCarbonCaptureModel(),
)
```

!!! note
    This excerpt (and the complete script file) showcase the final properly initialized mapping, but when developing, you are encouraged to make liberal use of the helper function [`to_initialize`](@ref) and check the PlantSimEngine user errors.

### Running a simulation 

We only need an MTG, and some weather data, and then we'll be set. Let's create a simple MTG : 

```@example usepkg
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

```@example usepkg
meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
nothing # hide
```

And we're good to go ! 

```@example usepkg
outs = run!(mtg, mapping, meteo_day)
```

If you query or display the MTG after simulation, you'll see it expanded and grew multiple internodes and leaves :

```@example usepkg
mtg
#get_n_leaves(mtg)
```

And that's it ! Feel free to tinker with the parameters and see when things break down, to get a feel for the simulation.

Of course, this is a very crude and unrealistic simulation, with many dubious assumptions and parameters. But significantly more complex modelling is possible using the same approach : XPalm runs using a few dozen models spread out over nine scales.

This is a three-part tutorial and continues in the [Expanding on the multiscale simulation](@ref) page.