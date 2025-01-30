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
julia> statuses, status_templates, reverse_multiscale_mapping, vars_need_init = PlantSimEngine.init_statuses(mtg, mapping);
```

```jldoctest mylabel
julia> outs = Dict("Leaf" => (:carbon_assimilation, :carbon_demand), "Soil" => (:soil_water_content,));
```

Pre-allocate the outputs as a dictionary:

```jldoctest mylabel
julia> preallocated_vars = PlantSimEngine.pre_allocate_outputs(statuses, status_templates, reverse_multiscale_mapping, vars_need_init, outs, 2);
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
function pre_allocate_outputs(statuses, statuses_template, reverse_multiscale_mapping, vars_need_init, outs, nsteps; type_promotion=nothing, check=true)
    outs_ = Dict{String,Vector{Symbol}}()
    for i in keys(outs) # i = "Plant"
        @assert isa(outs[i], Tuple{Vararg{Symbol}}) """Outputs for scale $i should be a tuple of symbols, *e.g.* `"$i" => (:a, :b)`, found `"$i" => $(outs[i])` instead."""
        outs_[i] = [outs[i]...]
    end

    statuses_ = copy(statuses_template)
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
            # The organ is not found in the mtg, we return an info and get along (it might be created during the simulation):
            check && @info "You required outputs for organ $organ, but this organ is not found in the provided MTG at this point."
        end
        if !all(i in collect(keys(statuses_[organ])) for i in vars)
            not_in_statuses = (setdiff(vars, keys(statuses_[organ]))...,)
            plural = length(not_in_statuses) == 1 ? "" : "s"
            e = string(
                "You requested outputs for variable", plural, " ",
                join(not_in_statuses, ", "),
                " in organ $organ, but ",
                length(not_in_statuses) == 1 ? "it has no model." : "they have no models."
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
                    outs_[organ] = [existing_vars_requested...]
                end
            end
        end

        if :node ∉ outs_[organ]
            push!(outs_[organ], :node)
        end
    end

    outs_tuple = Dict(i => Tuple(x for x in outs_[i]) for i in keys(outs_))

    node_types = []
    for o in keys(statuses)
        if length(statuses[o]) > 0
            push!(node_types, typeof(statuses[o][1].node))
        end
    end

    node_type = unique(node_types)
    @assert length(node_type) == 1 "All plant graph nodes should have the same type, found $(unique(node_type))."
    node_type = only(node_type)

    # Making the pre-allocated outputs:
    return Dict(organ => Dict(var => [var == :node ? node_type[] : typeof(status_from_template(statuses_template[organ])[var])[] for n in 1:nsteps] for var in vars) for (organ, vars) in outs_tuple)
    # Note: we use the type of the variable from the status template for each organ to pre-allocate the outputs. We transform the status template into a status to get the types of the variables
    # without the reference types, e.g. RefVector{Float64} becomes Vector{Float64}.
end

pre_allocate_outputs(statuses, status_templates, reverse_multiscale_mapping, vars_need_init, ::Nothing, nsteps; type_promotion=nothing, check=true) = Dict{String,Tuple{Symbol,Vararg{Symbol}}}()

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

function pre_allocate_outputs(m::ModelList, outs, nsteps; type_promotion=nothing, check=true)
    
    # NOTE : init_variables recreates a DependencyGraph, it's not great
    # TODO : copy ?
    out_vars_all = merge(init_variables(m; verbose=false)...)

    out_keys_requested = Symbol[]
    if !isnothing(outs)
        out_keys_requested = Symbol[outs...]
    end
    out_vars_requested = NamedTuple()

    # default implicit behaviour, track everything
    if isempty(out_keys_requested)
        #m.outputs = (keys(copy(status(m)))...)
        out_vars_requested = out_vars_all
    else
        unexpected_outputs = setdiff(out_keys_requested, status_keys(status(m)))

        if !isempty(unexpected_outputs)
            e = string(
                "You requested as output ",
                join(unexpected_outputs, ", "),
                "which are not found in any model."
            )

            if check
                error(e)
            else
                @info e
                [delete!(unexpected_outputs, i) for i in unexpected_outputs]
            end
        end    
        
        # get the default values from the tuple with all vars obtained from the modellist
        #[out_vars_requested = (i => out_vars_all[i], out_vars_requested...) for i in out_keys_requested]
        #for i in out_keys_requested
        #    merge(out_vars_requested, (i => out_vars_all[i],))
        #end
        out_defaults_requested = (out_vars_all[i] for i in out_keys_requested)
        out_vars_requested = (;zip(out_keys_requested, out_defaults_requested)...)
    end

    outputs_timestep = fill(out_vars_requested, nsteps)
    return TimeStepTable([Status(i) for i in outputs_timestep])
end

function save_results!(m::ModelList, outputs, i)
    outs = outputs[i]
    tst = status(m)
    st_row = tst[1]
    
    for var in keys(outs)
        outs[var] = st_row[var]
    end
end