# Fixing bugs in the plant simulation

There are two major issues hinted at in last chapter's implementation, which we'll discuss and resolve here.

You can find the full script for this simulation in the [ToyMultiScalePlantModel](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/ToyMultiScalePlantModel/ToyPlantSimulation3.jl) subfolder of the examples folder.

## Delaying organ maturity

There is one quirk you may have noticed when inspecting the data : when a root expands, the new root is immediately active, and some models may act on it immediately... including the root growth model. Meaning this new root may also sprout another root in the same timestep, and so on.

This is an implementation decision in PlantSimEngine. By default, new organs are active, and models can affect them as soon as they are created. 

The internode growth also depends on a threshold thermal time value, so doesn't immediately expand within a single timestep. XPalm's organ emission models TODO also 

!!! Note
    This may be subject to change in future versions of PlantSimEngine. Also note that the way the dependency graph is structured determines the order in which models run. Meaning that which models are run before or after organ creation might change with new additions and updates to your mapping. Some models might run "one timestep later".

How do we avoid this extreme instant growth ? We can, of course, add some thermal time constraint. We could arbitrarily tinker with water resources. 

We can otherwise add a simple state machine variable to our root and internodes in the MTG, indicating a newly added organ is immature and cannot grow on the same timestep. Since our root doesn't branch, we can simply keep track of a single state variable.

In fact, we could change the scale at which the check is made to extend the root, and have another model call this one directly. This enables running this model only for the end root when those occasional timesteps when root growth is possible, instead of at every timestep for every root node.

You can find several similar patterns in XPalm TODO.

## Fixing resource computation

Another problem you may have noticed, is that the water and carbon stock are computed by aggregating photosynthesis over leaves and absorption over roots... But they aren't always properly decremented when consumed !

If the end root grows, it outputs a carbon_root_creation_consumed value, but under certain conditions, we might also create other roots and internodes even when there shouldn't be enough carbon left for them. 

Indeed, if both the root and leaf water thresholds are met, and there is enough carbon for a single root or internode but not for both, and the root model runs before the internode model, both will use the carbon_stock variable prior to organ emission. The internode emission model won't account for the root carbon consumption.

This occurs because carbon_stock is only computed once, and won't update until the next timestep.

What we can do to avoid that problem in our specific case (for other situations TODO), is to couple the root growth model and the internode emission model, and pass the carbon_root_creation_consumed so that internode emission can take it into account. Or we could have an intermediate model recompute the new stock to pass along to the internode emission model. 

We'll go for the first option.

TODO previous timestep ?

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

### Root growth decision model with a hard dependency

Our root growth decision model inherits some of the responsibility from last chapter's root growth model, so inputs, parameters and condition checks will be similar. We'll let the root growth model keep the length check and only focus on resources.

```julia
PlantSimEngine.@process "root_growth_decision" verbose = false

struct ToyRootGrowthDecisionModel <: AbstractRoot_Growth_DecisionModel
    water_threshold::Float64
    carbon_root_creation_cost::Float64
end

PlantSimEngine.inputs_(::ToyRootGrowthDecisionModel) = 
(water_stock=0.0,carbon_stock=0.0)

PlantSimEngine.outputs_(::ToyRootGrowthDecisionModel) = NamedTuple()

PlantSimEngine.dep(::ToyRootGrowthDecisionModel) = (root_growth=AbstractRoot_GrowthModel=>["Root"],)

function PlantSimEngine.run!(m::ToyRootGrowthDecisionModel, models, status, meteo, constants=nothing, extra=nothing)

    if status.water_stock < m.water_threshold && status.carbon_stock > m.carbon_root_creation_cost
        status_Root= extra_args.statuses["Root"][1]
        PlantSimEngine.run!(extra.models["Root"].root_growth, models, status_Root, meteo, constants, extra)
    end
end
```

Note the hard dependency declaration, and the direct call to the root growth `run!` function. The root growth model will output the `carbon_root_creation_consumed` computation, but it'll still be exposed to downstream models despite the root growth model being an 'hidden' model since it's a hard dependency.

### Root growth

This version is a simplifed version of last chapter's.

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

TODO state machine

### Mapping adjustments

The new mapping only has straightforward changes. Some models cease to be multi-scale, others require new variables to be mapped for them. `carbon_root_creation_consumed` ceases to be a vector mapping and is a scalar variable.

```julia
mapping = Dict(
"Scene" => ToyDegreeDaysCumulModel(),
"Plant" => (
    MultiScaleModel(
        model=ToyStockComputationModel(),          
        mapping=[
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
            mapping=[:TT_cu => "Scene",
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

## Final words

The full script for this simulation can be found [here](https://github.com/VirtualPlantLab/PlantSimEngine.jl/blob/main/examples/ToyMultiScalePlantModel/ToyPlantSimulation3.jl), in the ToyMultiScalePlantModel subfolder of the examples folder.

We now have a plant with two different growth directions. Roots are added at the beginning, until water is considered abundant enough.

Of course, there are still several design issues with this implementation. It is as utterly unrealistic as the previous one, and doesn't even consume water. Some condition checking is a little ad hoc and could be made more robust. More sanity checks could be added, and the model and variable names could definitely be made more clear.

But once again, this example is only made to illustrate what is possible with this framework, and doesn't strive for ecophysiological consistency. And the approach can be made increasingly more complex by refining models and simulation parameters, and feeding in new information about your plant, and ramp up to realistic, production-ready and predictive simulations.