# Avoiding cyclic dependencies

When defining a mapping between models and scales, it is important to avoid cyclic dependencies. A cyclic dependency occurs when a model at a given scale depends on a model at another scale that depends on the first model. Cyclic dependencies are bad because they lead to an infinite loop in the simulation (the dependency graph keeps cycling indefinitely).

PlantSimEngine will detect cyclic dependencies and raise an error if one is found. The error message indicates the models involved in the cycle, and the model that is causing the cycle will be highlighted in red.

For example the following mapping will raise an error:

!!! details
    <summary>Example mapping</summary>
    
    ```julia
    mapping_cyclic = Dict(
        "Plant" => (
            MultiScaleModel(
                model=ToyCAllocationModel(),
                mapped_variables=[
                    :carbon_demand => ["Leaf", "Internode"],
                    :carbon_allocation => ["Leaf", "Internode"]
                ],
            ),
            MultiScaleModel(
                model=ToyPlantRmModel(),
                mapped_variables=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
            ),
            Status(total_surface=0.001, aPPFD=1300.0, soil_water_content=0.6),
        ),
        "Internode" => (
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
            Status(TT=10.0, carbon_biomass=1.0),
        ),
        "Leaf" => (
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
            ToyCBiomassModel(1.2),
            Status(TT=10.0),
        )
    )
    ```

Let's see what happens when we try to build the dependency graph for this mapping:

```julia
julia> dep(mapping_cyclic)
ERROR: Cyclic dependency detected in the graph. Cycle:
 Plant: ToyPlantRmModel
 └ Leaf: ToyMaintenanceRespirationModel
  └ Leaf: ToyCBiomassModel
   └ Plant: ToyCAllocationModel
    └ Plant: ToyPlantRmModel

 You can break the cycle using the `PreviousTimeStep` variable in the mapping.
```

How can we interpret the message? We have a list of five models involved in the cycle. The first model is the one causing the cycle, and the others are the ones that depend on it. In this case, the `ToyPlantRmModel` is the one causing the cycle, and the others are inter-dependent. We can read this as follows:

1. `ToyPlantRmModel` depends on `ToyMaintenanceRespirationModel`, the plant-scale respiration sums up all organs respiration;
2. `ToyMaintenanceRespirationModel` depends on `ToyCBiomassModel`, the organs respiration depends on the organs biomass;
3. `ToyCBiomassModel` depends on `ToyCAllocationModel`, the organs biomass depends on the organs carbon allocation;
4. And finally `ToyCAllocationModel` depends on `ToyPlantRmModel` again, hence the cycle because the carbon allocation depends on the plant scale respiration.

The models can not be ordered in a way that satisfies all dependencies, so the cycle can not be broken. To solve this issue, we need to re-think how models are mapped together, and break the cycle.

There are several ways to break a cyclic dependency:

- **Merge models**: If two models depend on each other because they need *e.g.* recursive computations, they can be merged into a third model that handles the computation and takes the two models as hard dependencies. Hard dependencies are models that are explicitly called by another model and do not participate on the building of the dependency graph.
- **Change models**: Of course models can be interchanged to avoid cyclic dependencies, but this is not really a solution, it is more a workaround.
- **PreviousTimeStep**: We can break the dependency graph by defining some variables as taken from the previous time step. A very well known example is the computation of the light interception by a plant that depends on the leaf area, which is usually the result of a model that also depends on the light interception. The cyclic dependency is usually broken by using the leaf area from the previous time step in the interception model, which is a good approximation for most cases.

We can fix our previous mapping by computing the organs respiration using the carbon biomass from the previous time step instead. Let's see how to fix the cyclic dependency in our mapping (look at the leaf and internode scales):

!!! details
    ```@julia
    mapping_nocyclic = Dict(
            "Plant" => (
                MultiScaleModel(
                    model=ToyCAllocationModel(),
                    mapping=[
                        :carbon_demand => ["Leaf", "Internode"],
                        :carbon_allocation => ["Leaf", "Internode"]
                    ],
                ),
                MultiScaleModel(
                    model=ToyPlantRmModel(),
                    mapped_variables=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
                ),
                Status(total_surface=0.001, aPPFD=1300.0, soil_water_content=0.6, carbon_assimilation=5.0),
            ),
            "Internode" => (
                ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                MultiScaleModel(
                    model=ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
                    mapped_variables=[PreviousTimeStep(:carbon_biomass),], #! this is where we break the cyclic dependency (first break)
                ),
                Status(TT=10.0, carbon_biomass=1.0),
            ),
            "Leaf" => (
                ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
                MultiScaleModel(
                    model=ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
                    mapped_variables=[PreviousTimeStep(:carbon_biomass),], #! this is where we break the cyclic dependency (second break)
                ),
                ToyCBiomassModel(1.2),
                Status(TT=10.0),
            )
        );
    nothing # hide
    ```

The `ToyMaintenanceRespirationModel` models are now defined as [`MultiScaleModel`](@ref), and the `carbon_biomass` variable is wrapped in a `PreviousTimeStep` structure. This structure tells PlantSimEngine to take the value of the variable from the previous time step, breaking the cyclic dependency.

!!! note
    [`PreviousTimeStep`](@ref) tells PlantSimEngine to take the value of the previous time step for the variable it wraps, or the value at initialization for the first time step. The value at initialization is the one provided by default in the models inputs, but is usually provided in the [`Status`](@ref) structure to override this default.
    A [`PreviousTimeStep`](@ref) is used to wrap the **input** variable of a model, with or without a mapping to another scale *e.g.* `PreviousTimeStep(:carbon_biomass) => "Leaf"`.