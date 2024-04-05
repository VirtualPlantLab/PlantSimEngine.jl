"""
    pre_allocate_outputs(statuses, outs, nsteps; check=true)

Pre-allocate the outputs of needed variable for each node type in vectors of vectors.
The first level vectors have length nsteps, and the second level vectors have length n_nodes of this type.

Note that we pre-allocate the vectors for the time-steps, but not for each organ, because we don't 
know how many nodes will be in each organ in the future (organs can appear or disapear).

# Arguments

- `statuses`: a dictionary of status by node type
- `outs`: a dictionary of outputs by node type
- `nsteps`: the number of time-steps
- `check`: whether to check the mapping for errors. Default (`true`) returns an error if some variables do not exist.
If false and some variables are missing, return an info, remove the unknown variables and continue.

# Returns

- A dictionary of pre-allocated output of vector of time-step and vector of node of that type.

# Examples

```jldoctest mylabel
julia> using PlantSimEngine, MultiScaleTreeGraph, PlantSimEngine.Examples
```

Import example models (can be found in the `examples` folder of the package, or in the `Examples` sub-modules): 

```jldoctest mylabel
julia> using PlantSimEngine.Examples;
```

Define the models mapping:

```jldoctest mylabel
julia> mapping = Dict( \
    "Plant" =>  ( \
        MultiScaleModel(  \
            model=ToyCAllocationModel(), \
            mapping=[ \
                :carbon_assimilation => ["Leaf"], \
                :carbon_demand => ["Leaf", "Internode"], \
                :carbon_allocation => ["Leaf", "Internode"] \
            ], \
        ), 
        MultiScaleModel(  \
            model=ToyPlantRmModel(), \
            mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],] \
        ), \
    ),\
    "Internode" => ( \
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), \
        ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004), \
        Status(TT=10.0, carbon_biomass=1.0) \
    ), \
    "Leaf" => ( \
        MultiScaleModel( \
            model=ToyAssimModel(), \
            mapping=[:soil_water_content => "Soil",], \
        ), \
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), \
        ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025), \
        Status(aPPFD=1300.0, TT=10.0, carbon_biomass=1.0), \
    ), \
    "Soil" => ( \
        ToySoilWaterModel(), \
    ), \
);
```

Importing an example MTG provided by the package:

```jldoctest mylabel
julia> mtg = import_mtg_example();
```

```jldoctest mylabel
julia> statuses, = PlantSimEngine.init_statuses(mtg, mapping);
```

```jldoctest mylabel
julia> outs = Dict("Leaf" => (:carbon_assimilation, :carbon_demand), "Soil" => (:soil_water_content,));
```

Pre-allocate the outputs as a dictionary:

```jldoctest mylabel
julia> preallocated_vars = PlantSimEngine.pre_allocate_outputs(statuses, outs, 2);
```

The dictionary has a key for each organ from which we want outputs:

```jldoctest mylabel
julia> collect(keys(preallocated_vars))
2-element Vector{String}:
 "Soil"
 "Leaf"
```

Each organ has a dictionary of variables for which we want outputs from, 
with the pre-allocated empty vectors (one per time-step that will be filled with one value per node):

```jldoctest mylabel
julia> collect(keys(preallocated_vars["Leaf"]))
3-element Vector{Symbol}:
 :carbon_assimilation
 :node
 :carbon_demand
```
"""
function pre_allocate_outputs(statuses, outs, nsteps; check=true)
    outs_ = copy(outs)

    # Checking that organs in outputs exist in the mtg (in the statuses):
    if !all(i in keys(statuses) for i in keys(outs_))
        not_in_statuses = setdiff(keys(outs_), keys(statuses))
        e = string(
            "You requested outputs for organs ",
            join(keys(outs_), ", "),
            ", but organs ",
            join(not_in_statuses, ", "),
            " have no models."
        )

        if check
            error(e)
        else
            @info e
            [delete!(outs_, i) for i in not_in_statuses]
        end
    end

    # Checking that variables in outputs exist in the statuses, and adding the :node variable:
    for (organ, vars) in outs_ # organ = "Leaf"; vars = outs_[organ]
        if length(statuses[organ]) == 0
            # The organ is not found in the mtg, we remove it from the outputs:
            e = "You required outputs for organ $organ, but this organ is not found in the provided MTG."

            if check
                error(e)
            else
                @info e
                delete!(outs_, organ)
            end
            continue
        end
        if !all(i in collect(keys(statuses[organ][1])) for i in vars)
            not_in_statuses = (setdiff(vars, keys(statuses[organ][1]))...,)
            e = string(
                "You requested outputs for variables ",
                join(vars, ", "),
                ", but variables ",
                join(not_in_statuses, ", "),
                " have no models."
            )
            if check
                error(e)
            else
                @info e
                existing_vars_requested = setdiff(outs_[organ], not_in_statuses)
                if length(existing_vars_requested) == 0
                    # None of the variables requested by the user exist at this scale for this set of models
                    delete!(outs_, organ)
                else
                    # Some still exist, we only use the ones that do:
                    outs_[organ] = (existing_vars_requested...,)
                end
            end
        end

        if :node ∉ outs_[organ]
            outs_[organ] = (outs_[organ]..., :node)
        end
    end

    # Making the pre-allocated outputs:
    Dict(organ => Dict(var => [typeof(statuses[organ][1][var])[] for n in 1:nsteps] for var in vars) for (organ, vars) in outs_)
    # Note: we use the type of the variable from the first status for each organ to pre-allocate the outputs, because they are
    # all the same type for others.
end

pre_allocate_outputs(statuses, ::Nothing, nsteps; check=true) = Dict{String,Tuple{Symbol,Vararg{Symbol}}}()

"""
    save_results!(object::GraphSimulation, i)

Save the results of the simulation for time-step `i` into the 
object. For a `GraphSimulation` object, this will save the results
from the `status(object)` in the `outputs(object)`.
"""
function save_results!(object::GraphSimulation, i)
    outs = outputs(object)
    statuses = status(object)

    for (organ, vars) in outs
        for (var, values) in vars
            values[i] = [status[var] for status in statuses[organ]]
        end
    end
end