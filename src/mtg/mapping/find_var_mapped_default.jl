
"""

"""
function find_var_mapped_default(mapping, organ)
    map_vars = get_mapping(mapping[organ])

    if length(map_vars) == 0
        return
    end

    mods = get_models(mapping[organ])
    ins = merge(inputs_.(mods)...)
    outs = merge(outputs_.(mods)...)

    find_var_mapped_default(mapping, organ, map_vars, ins, outs)
end


"""
    find_var_mapped_default(mapping, organ, map_vars, ins, outs)
    find_var_mapped_default(mapping, organ)

Find the default values for variables mapped from one scale to another scale in a mapping.

# Arguments

- `mapping`: A dictionary representing the mapping between models and scales.
- `organ`: The scale for which the variables are being mapped.
- `map_vars`: A dictionary containing the variables to be mapped and their corresponding scales.
- `ins`: The input variables for the scale.
- `outs`: The output variables for the scale.

# Returns

An array of key-value pairs representing the variables and their default values.

# Example

```julia
find_var_mapped_default(mapping, "Leaf")
````
"""
function find_var_mapped_default(mapping, organ, map_vars, ins, outs)

    rev_mapping = reverse_mapping(mapping; all=true)

    multi_scale_vars_vec = Pair{Symbol,Any}[]
    for (var, scales) in map_vars # e.g. var = :leaf_area; scales = ["Leaf"]
        if isa(scales, AbstractString)
            if hasproperty(ins, var) && isa(ins[var], AbstractVector) ||
               hasproperty(outs, var) && isa(outs[var], AbstractVector)
                error(
                    "In mapping for organ $organ, variable $var is mapped to a single node type, but its default value is a vector. " *
                    """Did you mean to map it to a vector of nodes? If so, your mapping should be: `:$var => ["$scales"]` """ *
                    """instead of `:$var => "$scales"`."""
                )
            end
            scales = [scales]
        end

        # The variable default value is always taken from the upper-stream model:
        if hasproperty(ins, var) # e.g. var = :leaf_area
            # The variable is taken as an input from another scale. We take its default value from the model at the other scale:
            mapped_out_var = []
            #! Should this part done recursively? At the moment we check if a second scale that is mapped into the first scale has the 
            #! variable that we need, and if not, if this variable is computed by another scale onto this scale. But it can be recursively
            #! be computed by another scale and yet another from scale to scale.
            for s in scales # s = scales[1]
                @assert haskey(mapping, s) "Scale $s required as a mapping for scale $organ, but not found in the mapping."
                mapped_out = merge(outputs_.(get_models(mapping[s]))...)

                if !hasproperty(mapped_out, var)
                    # The variable is not found, maybe it comes from the Status given by the user (1).
                    # If not, it may be computed by yet another scale and mapped into the second scale (s). 
                    # Checking if this is the case (2), and return an error otherwise (3).
                    st_mapped_out = get_status(mapping[s])
                    if hasproperty(st_mapped_out, var) # Case 1
                        push!(mapped_out_var, st_mapped_out[var])
                    else
                        # Maybe some other scale computes it for this scale (Case 2):
                        found = [false]
                        for (s_mapping, vars_mapping) in rev_mapping[s]
                            # # The reverse mapping necessarily points to the current scale, so we don't check this:
                            # s_mapping == organ && continue

                            # If the variable is found as a mapping of yet another scale:
                            if var in unique(vars_mapping)
                                mapped_out_other = merge(outputs_.(get_models(mapping[s_mapping]))...)
                                # And it is an output of this scale:

                                if var in keys(mapped_out_other)
                                    # push!(mapped_out_var, mapped_out_other[var])
                                    # We take the default value from the down-stream model as it is this one 
                                    # that is supposed to define if it is a vector or a single value:
                                    push!(mapped_out_var, ins[var])

                                    found[1] = true
                                    break
                                end
                            end
                        end

                        # Case 3
                        if !found[1]
                            error("No model computes variable $var at scale $s, or at any other scale mapping into it ($s_mapping), and variable $var is needed for scale $organ.")
                        end
                    end
                else
                    push!(mapped_out_var, mapped_out[var])
                end
            end

            mapped_out = unique(mapped_out_var)
            if length(mapped_out) > 1
                @info "Found different default values for variable $var in mapping at scales $scales: $mapped_out. Taking the first one."
            end
            mapped_out = mapped_out[1]

            # If the variable is given as a vector as default value, it means it will be taken from several organs.
            # In this case, we keep the vector format:
            if isa(ins[var], AbstractVector)
                mapped_out = fill(mapped_out, length(ins[var]))
            end
            push!(multi_scale_vars_vec, var => mapped_out)
        elseif hasproperty(outs, var)
            # The variable is an output of this scale for another scale. We take its default value from this scale:
            push!(multi_scale_vars_vec, var => outs[var])
        else
            error("Variable $var required to be mapped from scale(s) $scales to scale $organ was not found in any model from the scale(s) $scales.")
        end
    end

    return multi_scale_vars_vec
end