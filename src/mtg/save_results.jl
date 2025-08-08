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
            mapped_variables=[ \
                :carbon_assimilation => ["Leaf"], \
                :carbon_demand => ["Leaf", "Internode"], \
                :carbon_allocation => ["Leaf", "Internode"] \
            ], \
        ), 
        MultiScaleModel(  \
            model=ToyPlantRmModel(), \
            mapped_variables=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],] \
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
            mapped_variables=[:soil_water_content => "Soil",], \
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

    # default behaviour : track everything
    if isnothing(outs)
        for organ in keys(statuses)
            outs_[organ] = [keys(statuses_template[organ])...]
        end
        # No outputs requested by user : just return the timestep and node
    elseif length(outs) == 0
        for i in keys(statuses)
            outs_[i] = []
        end
    else
        for i in keys(outs) # i = "Plant"
            @assert isa(outs[i], Tuple{Vararg{Symbol}}) """Outputs for scale $i should be a tuple of symbols, *e.g.* `"$i" => (:a, :b)`, found `"$i" => $(outs[i])` instead."""
            outs_[i] = [outs[i]...]
        end
    end

    len = Dict{String,Int}()
    for (organ, vals) in outs_
        len[organ] = length(outs_[organ])
        unique!(outs_[organ])
    end


    for (organ, vals) in outs_
        if length(outs_[organ]) != len[organ]
            @info "One or more requested output variable duplicated at scale $organ, removed it"
        end
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

    node_types = []
    for o in keys(statuses)
        if length(statuses[o]) > 0
            push!(node_types, typeof(statuses[o][1].node))
        end
    end

    node_type = unique(node_types)
    @assert length(node_type) == 1 "All plant graph nodes should have the same type, found $(unique(node_type))."
    node_type = only(node_type)

    # I don't know if this function barrier is necessary
    preallocated_outputs = Dict{String,Vector}()
    complete_preallocation_from_types!(preallocated_outputs, nsteps, outs_, node_type, statuses_template)
    return preallocated_outputs
end

function complete_preallocation_from_types!(preallocated_outputs, nsteps, outs_, node_type, statuses_template)
    types = Vector{DataType}()
    for organ in keys(outs_)

        outs_no_node = filter(x -> x != :node, outs_[organ])

        #types = [typeof(status_from_template(statuses_template[organ])[var]) for var in outs[organ]]
        values = [status_from_template(statuses_template[organ])[var] for var in outs_no_node]

        #push!(types, node_type)

        # contains :node
        symbols_tuple = (:timestep, :node, outs_no_node...,)
        # using node_type.parameters[1] is clunky, but covers both NodeMTG and AbstractNodeMTG types
        values_tuple = (1, MultiScaleTreeGraph.Node((node_type.parameters[1])("/", "Uninitialized", 0, 0),), values...,)

        # Dummy value to make accessing the type easier 
        # (empty arrays don't have references to an instance, so their types can't be inspected and manipulated as easily)
        dummy_status = (; zip(symbols_tuple, values_tuple)...)
        data = typeof(Status(dummy_status))[]
        resize!(data, nsteps)

        for ii in 1:nsteps
            data[ii] = Status(dummy_status)
        end
        preallocated_outputs[organ] = data
    end
end


"""
    save_results!(object::GraphSimulation, i)

Save the results of the simulation for time-step `i` into the 
object. For a `GraphSimulation` object, this will save the results
from the `status(object)` in the `outputs(object)`.
"""
function save_results!(object::GraphSimulation, i)
    outs = outputs(object)

    if length(outs) == 0
        return
    end

    statuses = status(object)
    indexes = object.outputs_index
    for organ in keys(outs)

        if length(outs[organ]) == 0
            continue
        end

        index = indexes[organ]

        # Samuel : Simple resizing heuristic
        # This can be made much more conservative with the right heuristic, or with user hints
        # The array filling bit of code is clunky, but building NamedTuples on the fly was tanking performance
        # And it wasn't straightforward to avoid Status Ref reallocations causing performance issues
        # I then tried various approaches with Status, resizing, using fill, deepcopying, ...
        # I may have gotten a little confused while fighting the type system
        # So there may be possible simplifications (maybe no need for a function barrier, perhaps the resizing could be made a one-liner...)
        # But this should work without causing visible performance regressions on XPalm
        len = length(outs[organ])
        if length(statuses[organ]) + index - 1 > len
            min_required = max(length(statuses[organ]) + index - len, index)

            extra_length = 2 * min_required - len
            data = eltype(outs[organ])[]
            resize!(data, extra_length)
            dummy_value = NamedTuple(outs[organ][1])
            # TODO set timestep to 0 for clarity ?

            # Using fill! caused Ref issues, so call a Status constructor here instead of passing a prebuilt value
            # This will avoid having all array entries point to the same ref but keep construction cost at a minimum
            for new_entry in 1:extra_length
                data[new_entry] = Status(dummy_value)
            end

            outs[organ] = cat(outs[organ], data, dims=1)
            #println("len : ", len, " statuses #", length(statuses[organ]), " index ", index)
            #println("min_required : ", min_required, " extra_length ", extra_length, " new len ", length(outs[organ]))
        end

        tracked_outputs = filter(i -> i != :timestep, keys(outs[organ][1]))

        indexes[organ] = copy_tracked_outputs_into_vector!(outs[organ], i, statuses[organ], tracked_outputs, indexes[organ])
    end
end

function copy_tracked_outputs_into_vector!(outs_organ, i, statuses_organ, tracked_outputs, index)
    j = index
    for status in statuses_organ
        outs_organ[j].timestep = i
        for var in tracked_outputs
            outs_organ[j][var] = status[var]
        end
        j += 1
    end
    return j
end

function pre_allocate_outputs(m::ModelList, outs, nsteps; type_promotion=nothing, check=true)
    st, = flatten_status(status(m))
    out_vars_all = convert_vars(st, type_promotion)

    out_keys_requested = Symbol[]
    if !isnothing(outs)
        if length(outs) == 0 # no outputs desired, for some reason
            return NamedTuple()
        end
        out_keys_requested = Symbol[outs...]
    end
    out_vars_requested = NamedTuple()

    # default implicit behaviour, track everything
    if isempty(out_keys_requested)
        # We already have the status here, just repeating its value:
        out_vars_requested = NamedTuple(out_vars_all)
    else
        unexpected_outputs = setdiff(out_keys_requested, keys(st))

        if !isempty(unexpected_outputs)
            e = string(
                "You requested as output ",
                join(unexpected_outputs, " ,"),
                " not found in any model."
            )

            if check
                error(e)
            else
                @info e
                [delete!(unexpected_outputs, i) for i in unexpected_outputs]
            end
        end

        out_defaults_requested = (out_vars_all[i] for i in out_keys_requested)
        out_vars_requested = (; zip(out_keys_requested, out_defaults_requested)...)
    end

    return TimeStepTable([Status(out_vars_requested) for i in Base.OneTo(nsteps)])
end

function save_results!(status_flattened::Status, outputs, i)
    if length(outputs) == 0
        return
    end
    outs = outputs[i]

    for var in keys(outs)
        outs[var] = status_flattened[var]
    end
end