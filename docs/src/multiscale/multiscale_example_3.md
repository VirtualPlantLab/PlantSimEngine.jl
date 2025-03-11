# Fixing bugs in the plant simulation

```@setup usepkg
using PlantSimEngine
using PlantSimEngine.Examples
using PlantMeteo, CSV, DataFrames
using MultiScaleTreeGraph
function get_root_end_node(node::MultiScaleTreeGraph.Node)
    root = MultiScaleTreeGraph.get_root(node)
    return MultiScaleTreeGraph.traverse(root, x->x, symbol="Root", filter_fun = MultiScaleTreeGraph.isleaf)
end

function get_roots_count(node::MultiScaleTreeGraph.Node)
    root = MultiScaleTreeGraph.get_root(node)
    return length(MultiScaleTreeGraph.traverse(root, x->x, symbol="Root"))
end

function get_n_leaves(node::MultiScaleTreeGraph.Node)
    root = MultiScaleTreeGraph.get_root(node)
    nleaves = length(MultiScaleTreeGraph.traverse(root, x->1, symbol="Leaf"))
    return nleaves
end

PlantSimEngine.@process "organ_emergence" verbose = false

struct ToyCustomInternodeEmergence{T} <: AbstractOrgan_EmergenceModel
    TT_emergence::T
    carbon_internode_creation_cost::T
    leaf_surface_area::T
    leaves_max_surface_area::T
    water_leaf_threshold::T
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

############################
# Naive water absorption model
# Absorbs precipitation water depending on quantity of roots 
############################
PlantSimEngine.@process "water_absorption" verbose = false

struct ToyWaterAbsorptionModel <: AbstractWater_AbsorptionModel
end

PlantSimEngine.inputs_(::ToyWaterAbsorptionModel) = (root_water_assimilation=1.0,)
PlantSimEngine.outputs_(::ToyWaterAbsorptionModel) = (water_absorbed=0.0,)

function PlantSimEngine.run!(m::ToyWaterAbsorptionModel, models, status, meteo, constants=nothing, extra=nothing)
    #root_end = get_root_end_node(status.node)
    #root_len = root_end[:Root_len]
    status.water_absorbed = meteo.Precipitations * status.root_water_assimilation #* root_len
end

PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyWaterAbsorptionModel}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyWaterAbsorptionModel}) = PlantSimEngine.IsObjectIndependent()


##########################
### Root growth : when water stocks are low, expand root
##########################

PlantSimEngine.@process "root_growth" verbose = false

struct ToyRootGrowthModel{T} <: AbstractRoot_GrowthModel
    water_threshold::T
    carbon_root_creation_cost::T
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

##########################
### Model accumulating carbon and water resources 
##########################

PlantSimEngine.@process "resource_stock_computation" verbose = false

struct ToyStockComputationModel <: AbstractResource_Stock_ComputationModel
end
#status.water_stock += meteo.precipitations * root_water_assimilation_ratio

PlantSimEngine.inputs_(::ToyStockComputationModel) = 
(water_absorbed=0.0,carbon_captured=0.0,carbon_organ_creation_consumed=0.0,carbon_root_creation_consumed=0.0)

PlantSimEngine.outputs_(::ToyStockComputationModel) = (water_stock=-Inf,carbon_stock=-Inf)

function PlantSimEngine.run!(m::ToyStockComputationModel, models, status, meteo, constants=nothing, extra=nothing)
    status.water_stock += sum(status.water_absorbed) #- status.water_transpiration
    status.carbon_stock += sum(status.carbon_captured) - sum(status.carbon_organ_creation_consumed) - sum(status.carbon_root_creation_consumed)

    if status.water_stock < 0.0
        status.water_stock = 0.0
    end
end

PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyStockComputationModel}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyStockComputationModel}) = PlantSimEngine.IsObjectIndependent()

########################
## Leaf model capturing some arbitrary carbon quantity
########################

PlantSimEngine.@process "leaf_carbon_capture" verbose = false

struct ToyLeafCarbonCaptureModel<: AbstractLeaf_Carbon_CaptureModel end

function PlantSimEngine.inputs_(::ToyLeafCarbonCaptureModel)
    NamedTuple()#(TT_cu=-Inf)
end

function PlantSimEngine.outputs_(::ToyLeafCarbonCaptureModel)
    (carbon_captured=0.0,)
end

function PlantSimEngine.run!(::ToyLeafCarbonCaptureModel, models, status, meteo, constants, extra)   
    # very crude approximation with LAI of 1 and constant PPFD
    status.carbon_captured = 200.0 *(1.0 - exp(-0.2))
end

PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyLeafCarbonCaptureModel}) = PlantSimEngine.IsObjectIndependent()
PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyLeafCarbonCaptureModel}) = PlantSimEngine.IsTimeStepIndependent()

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
    
```

There are two major issues hinted at in last chapter's implementation, which we'll discuss and resolve here.

You can find the full script for this simulation in the [ToyMultiScalePlantModel](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/ToyMultiScalePlantModel/ToyPlantSimulation3.jl) subfolder of the examples folder.

```@contents
Pages = ["multiscale_example_3.md"]
Depth = 3
```

## An organ creation problem

There is one quirk you may have noticed when inspecting the data : when a root expands, the new root is immediately active, and some models may act on it immediately... including the root growth model. Meaning this new root may also sprout another root in the same timestep, and so on.

You can notice this by looking at the simulation's state after the first timestep:

```@example usepkg
outs = run!(mtg, mapping, first(meteo_day, 2))
outs["Root"][:node]
```

Yeah, our root immediately grew to full length.

This is an implementation decision in PlantSimEngine. By default, new organs are active, and models can affect them as soon as they are created. 

The internode growth depends on a threshold thermal time value, which accumulates over several timesteps, so even though new internodes are immediately active, they can't themselves grow new organs within the same timestep. 

This quirk is also avoided in [XPalm.jl](https://github.com/PalmStudio/XPalm.jl), a package using PlantSimEngine: some organs make use of state machines, and are considered "immature" when they are created. Immature organs cannot grow new organs until some conditions are met for their state to change. There are also other conditions governing organ emergence, such as specific threshold values relating to Thermal Time (see [here](https://github.com/PalmStudio/XPalm.jl/blob/433e1c47c743e7a53e764672818a43ed8feb10c6/src/plant/phytomer/leaves/phyllochron.jl#L46) for an example).

!!! Note
    This implementation decision for new organs to be immediately active may be subject to change in future versions of PlantSimEngine. Also note that the way the dependency graph is structured determines the order in which models run. Meaning that which models are run before or after organ creation might change with new additions and updates to your mapping. Some models might run "one timestep later", see [Simulation order instability when adding models](@ref) for more details.
### Delaying organ maturity

How do we avoid this extreme instant growth ? We can, of course, add some thermal time constraint. We could arbitrarily tinker with water resources. 

We can otherwise add a simple state machine variable to our root and internodes in the MTG, indicating a newly added organ is immature and cannot grow on the same timestep. Since our root doesn't branch, we can simply keep track of a single state variable.

In fact, we could change the scale at which the check is made to extend the root, and have another model call this one directly. This enables running this model only for the end root when those occasional timesteps when root growth is possible, instead of at every timestep for every root node.

## A resource distribution bug

Another problem you may have noticed, is that the water and carbon stock are computed by aggregating photosynthesis over leaves and absorption over roots... But they aren't always properly decremented when consumed !

If the end root grows, it outputs a `carbon_root_creation_consumed` value, but under certain conditions, we might also create other roots and internodes even when there shouldn't be enough carbon left for them. 

Indeed, if both the root and leaf water thresholds are met, and there is enough carbon for a single root or internode but not for both, and the root model runs before the internode model, both will use the carbon_stock variable prior to organ emission. The internode emission model won't account for the root carbon consumption.

This occurs because `carbon_stock` is only computed once, and won't update until the next timestep.

### Fixing resource computation: a root growth decision model

To avoid that problem in our specific case, we can couple the root growth model and the internode emission model, and pass the `carbon_root_creation_consumed` variable to the internode emission model so that it can use an updated carbon stock. Or we could have an intermediate model recompute the new stock to pass along to the internode emission model. 

There is a section in the [Tips and workarounds] page discussing this situation and other potential solutions: [Having a variable simultaneously as input and output of a model](@ref).

We'll go for the first option and couple the root growth and internode emission model.

### Internode emission adjustments

The only change required for our internode emission model is to take into account `carbon_root_creation_consumed` as a new input, map that variable from the "Root" scale in our mapping, and compute the adjusted carbon stock. Here's the relevant excerpt in the `run!` function.

```julia
 # take into account that the stock may already be depleted 
    carbon_stock_updated_after_roots = status.carbon_stock - status.carbon_root_creation_consumed

    # if not enough carbon, no organ creation
    if carbon_stock_updated_after_roots < m.carbon_internode_creation_cost
        return nothing
    end
```

### A multi-scale hard dependency appears

Our root growth decision model inherits some of the responsibility from last chapter's root growth model, so inputs, parameters and condition checks will be similar. We'll let the root growth model keep the length check and only focus on resources.

Since the decision model is now directly responsible for calling the actual root growth model, we need to declare that it requires a root growth model as a hard dependency and cannot be run standalone. 

This hard dependency is in fact multiscale, since both models operate at different scales, "Plant" and "Root". You can read more about multi-scale hard dependencies in the [Handling dependencies in a multiscale context](@ref) page.

Compared to the single-scale equivalent, the multi-scale declaration additionally requires mapping the scale:

```julia
PlantSimEngine.dep(::ToyRootGrowthDecisionModel) = (root_growth=AbstractRoot_GrowthModel=>["Root"],)
```

The `status` argument `run!` function of the root growth decision model only contains variables from the "Plant" scale, or explicitely mapped to this scale, which isn't the case for the root growth's variables. To make use of the root growth model's variables, we need to recover the `status` at the "Root" scale. It is accessible from the `extra` argument in `run!`'s signature. 

In multi-scale simulations, this `extra` argument implicitely contains an object storing the simulation state. It contains the statuses at various scales, and all the models indexed per scale and process name.

Access to the "Root" status within the root growth decision model `run!` function is done like so:

```julia
status_Root= extra_args.statuses["Root"][1]
```

It is then possible to call the root growth model from the parent's `run!` function:

```julia
PlantSimEngine.run!(extra.models["Root"].root_growth, models, status_Root, meteo, constants, extra)
```

Which will enable writing the rest of the `run!` function.

### Root growth decision model implementation

With that new coupling consideration properly handled, we can complete the full model implementation:

```julia
PlantSimEngine.@process "root_growth_decision" verbose = false

struct ToyRootGrowthDecisionModel{T} <: AbstractRoot_Growth_DecisionModel
    water_threshold::T
    carbon_root_creation_cost::T
end

PlantSimEngine.inputs_(::ToyRootGrowthDecisionModel) = 
(water_stock=0.0,carbon_stock=0.0)

PlantSimEngine.outputs_(::ToyRootGrowthDecisionModel) = NamedTuple()

PlantSimEngine.dep(::ToyRootGrowthDecisionModel) = (root_growth=AbstractRoot_GrowthModel=>["Root"],)

# "status" is at the "Plant" scale
function PlantSimEngine.run!(m::ToyRootGrowthDecisionModel, models, status, meteo, constants=nothing, extra=nothing)

    if status.water_stock < m.water_threshold && status.carbon_stock > m.carbon_root_creation_cost
        # Obtain "status" at "Root" scale
        status_Root= extra_args.statuses["Root"][1]
        # Call the hard dependency model directly with its status
        PlantSimEngine.run!(extra.models["Root"].root_growth, models, status_Root, meteo, constants, extra)
    end
end
```

The root growth model will output the `carbon_root_creation_consumed` computation, but it'll still be exposed to downstream models despite the root growth model being a 'hidden' model in the dependency graph due to its hard dependency nature.

With this new coupling, we will only be creating at most a single new root per timestep, as the root growth decision will only be called once per timestep. 

### Root growth

This iteration turns into a simplifed version of last chapter's.

```julia
PlantSimEngine.@process "root_growth" verbose = false

struct ToyRootGrowthModel <: AbstractRoot_GrowthModel
    root_max_len::Int
end

PlantSimEngine.inputs_(::ToyRootGrowthModel) = NamedTuple()
PlantSimEngine.outputs_(::ToyRootGrowthModel) = (carbon_root_creation_consumed=0.0,)

function PlantSimEngine.run!(m::ToyRootGrowthModel, models, status, meteo, constants=nothing, extra=nothing)    
    status.carbon_root_creation_consumed = 0.0

    root_end = get_root_end_node(status.node)
        
    if length(root_end) != 1 
        throw(AssertionError("Couldn't find MTG leaf node with symbol \"Root\""))
    end
    
    root_len = get_roots_count(root_end[1])
    if root_len < m.root_max_len
        st = add_organ!(root_end[1], extra, "<", "Root", 2, index=1)
        status.carbon_root_creation_consumed = m.carbon_root_creation_cost
    end
end
```

### Mapping adjustments

The new mapping only has straightforward changes. Some models cease to be multi-scale, others require new variables to be mapped for them. `carbon_root_creation_consumed` ceases to be a vector mapping and is a scalar variable.

```julia
mapping = Dict(
"Scene" => ToyDegreeDaysCumulModel(),
"Plant" => (
    MultiScaleModel(
        model=ToyStockComputationModel(),          
        mapped_variables=[
            :carbon_captured=>["Leaf"],
            :water_absorbed=>["Root"],
            :carbon_root_creation_consumed=>"Root",
            :carbon_organ_creation_consumed=>["Internode"]

        ],
        ),
    MultiScaleModel(
        model=ToyRootGrowthDecisionModel(10.0, 50.0),
    ),
        Status(water_stock = 0.0, carbon_stock = 0.0)
    ),
"Internode" => (        
        MultiScaleModel(
            model=ToyCustomInternodeEmergence(),#TT_emergence=20.0),
            mapped_variables=[:TT_cu => "Scene",
            :water_stock=>"Plant",
            :carbon_stock=>"Plant", 
            :carbon_root_creation_consumed=>"Root"],
        ),        
        Status(carbon_organ_creation_consumed=0.0),
    ),
"Root" =>   (ToyRootGrowthModel(10),       
            ToyWaterAbsorptionModel(),
            Status(carbon_root_creation_consumed=0.0, root_water_assimilation=1.0),
            ),
"Leaf" => ( ToyLeafCarbonCaptureModel(),),
)
```

We can now run our simulation as we did previously... or can we ?

```julia
ERROR: Cyclic dependency detected for process resource_stock_computation: resource_stock_computation for organ Plant depends on root_growth from organ Root, which depends on the first one. This is not allowed, you may need to develop a new process that does the whole computation by itself.
```

Ah, it looks like our additional usage of the root carbon cost creates a cyclic dependency. 

### Breaking the dependency cycle

Fortunately, the logic here is quite straightforward. We can't be computing our current timestep's resource stock with `carbon_root_creation_consumed`, and then updating it right after root creation again using a new value of `carbon_root_creation_consumed`.

The solution is hopefully quite intuitive : when we compute resource stocks, we should be computing it using the previous timestep's values. Then root creation happens (or doesn't), and the computed `carbon_root_creation_consumed` corresponds to the current timestep value. We could also do the same for water to be consistent.

### Updated mapping

The relevant part of the mapping that needs to be updated is the following:

```julia
mapping = Dict(
...
"Plant" => (
    MultiScaleModel(
        model=ToyStockComputationModel(),          
        mapped_variables=[
            :carbon_captured=>["Leaf"],
            :water_absorbed=>["Root"],
            PreviousTimeStep(:carbon_root_creation_consumed)=>"Root",
            PreviousTimeStep(:carbon_organ_creation_consumed)=>["Internode"],
        ],
        ),
        ToyRootGrowthDecisionModel(10.0, 50.0),
        Status(water_stock = 0.0, carbon_stock = 0.0)
    ),
...
)
```

## Final words

And you're now ready to run the simulation.

The full script can be found [here](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/ToyMultiScalePlantModel/ToyPlantSimulation3.jl), in the ToyMultiScalePlantModel subfolder of the examples folder.

We now have a plant with two different growth directions. Roots are added at the beginning, until water is considered abundant enough.

Of course, there are still several design issues with this implementation. It is as utterly unrealistic as the previous one, and doesn't even consume water. Some condition checking is a little ad hoc and could be made more robust. More sanity checks could be added, and the model and variable names could definitely be made more clear.

But once again, this example is only made to illustrate what is possible with this framework, and doesn't strive for ecophysiological consistency. And the approach can be made increasingly more complex by refining models and simulation parameters, and feeding in new information about your plant, and ramp up to realistic, production-ready and predictive simulations.