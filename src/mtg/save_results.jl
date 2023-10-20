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
julia> using PlantSimEngine, MultiScaleTreeGraph
```

```jldoctest mylabel
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToyAssimModel.jl"));
```

```jldoctest mylabel
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToyCDemandModel.jl"));
```

```jldoctest mylabel
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToyCAllocationModel.jl"));
```

```jldoctest mylabel
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/ToySoilModel.jl"));
```

```jldoctest mylabel
julia> mapping = Dict( \
            "Plant" => \
                MultiScaleModel( \
                    model=ToyCAllocationModel(), \
                    mapping=[ \
                        :A => ["Leaf"], \
                        :carbon_demand => ["Leaf", "Internode"], \
                        :carbon_allocation => ["Leaf", "Internode"] \
                    ], \
                ), \
            "Internode" => ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), \
            "Leaf" => ( \
                MultiScaleModel( \
                    model=ToyAssimModel(), \
                    mapping=[:soil_water_content => "Soil",], \
                ), \
                ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), \
                Status(aPPFD=1300.0, TT=10.0), \
            ), \
            "Soil" => ( \
                ToySoilWaterModel(), \
            ), \
        );
```

```jldoctest mylabel
julia> mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0));
```

```jldoctest mylabel
julia> soil = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Soil", 1, 1));
```

```jldoctest mylabel
julia> plant = Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1));
```

```jldoctest mylabel
julia> internode1 = Node(plant, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2));
```

```jldoctest mylabel
julia> leaf1 = Node(internode1, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2));
```

```jldoctest mylabel
julia> internode2 = Node(internode1, MultiScaleTreeGraph.NodeMTG("<", "Internode", 1, 2));
```

```jldoctest mylabel
julia> leaf2 = Node(internode2, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2));
```

```jldoctest mylabel
julia> organs_statuses = PlantSimEngine.status_template(mapping, nothing);
```

```jldoctest mylabel
julia> var_refvector = PlantSimEngine.reverse_mapping(mapping, all=false);
```

```jldoctest mylabel
julia> var_need_init = PlantSimEngine.to_initialize(mapping, mtg);
```

```jldoctest mylabel
julia> statuses = PlantSimEngine.init_statuses(mtg, organs_statuses, var_refvector, var_need_init);
```

```jldoctest mylabel
julia> outputs = Dict("Leaf" => (:A, :carbon_demand), "Soil" => (:soil_water_content,));
```

Pre-allocate the outputs as a dictionary:

```jldoctest mylabel
julia> outs = PlantSimEngine.pre_allocate_outputs(statuses, outputs, 2);
```

The dictionary has a key for each organ from which we want outputs:

```jldoctest mylabel
julia> collect(keys(outs))
2-element Vector{String}:
 "Soil"
 "Leaf"
```

Each organ has a dictionary of variables for which we want outputs from, 
with the pre-allocated empty vectors (one per time-step that will be filled with one value per node):

```jldoctest mylabel
julia> collect(keys(outs["Leaf"]))
3-element Vector{Symbol}:
 :A
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
    for (organ, vars) in outs_
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