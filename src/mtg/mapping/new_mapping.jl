"""
    mapped_variables(mapping, dependency_graph=dep(mapping); verbose=false)

Get the variables for each organ type from a dependency graph, with `MappedVar`s for the multiscale mapping.

# Arguments

- `mapping::Dict{String,T}`: the mapping between models and scales.
- `dependency_graph::DependencyGraph`: the dependency graph.
- `verbose::Bool`: whether to print the stacktrace of the search for the default value in the mapping.
"""
function mapped_variables(mapping, dependency_graph=dep(mapping); verbose=false)
    # Initialise a dict that defines the multiscale variables for each organ type:
    mapped_vars = mapped_variables_no_outputs_from_other_scale(mapping, dependency_graph)

    # Add the variables that are outputs from another scale and not computed at a scale otherwise, and add them to the organs_mapping:
    add_mapped_variables_with_outputs_as_inputs!(mapped_vars)
    # E.g.: carbon allocation is computed at the plant scale, but then allocated to each organ (Leaf and Internode) from the same model.
    # Which means that the Leaf and Internodes scales should have the carbon allocation as an input variable.

    # Find variables that are inputs to other scales as a `SingleNodeMapping` and declare them as MappedVar from themselves in the source scale.
    # This helps us declare it as a reference when we create the template status objects.
    transform_single_node_mapped_variables_as_self_node_output!(mapped_vars)

    mapped_vars_per_organ = merge(merge, mapped_vars[:inputs], mapped_vars[:outputs])

    mapped_vars = default_variables_from_mapping(mapped_vars_per_organ, verbose)

    return mapped_vars
end

"""
    mapped_variables_no_outputs_from_other_scale(mapping, dependency_graph=dep(mapping))

Get the variables for each organ type from a dependency graph, without the variables that are outputs from another scale.

# Arguments

- `mapping::Dict{String,T}`: the mapping between models and scales.
- `dependency_graph::DependencyGraph`: the dependency graph.

# Details

This function returns a dictionary with the (multiscale-) inputs and outputs variables for each organ type. 

Note that this function does not include the variables that are outputs from another scale and not computed by this scale,
see `mapped_variables_with_outputs_as_inputs` for that.
 """
function mapped_variables_no_outputs_from_other_scale(mapping, dependency_graph=dep(mapping))
    nodes_ins = Dict{String,Any}(org => [] for org in keys(mapping))
    nodes_outs = Dict{String,Any}(org => [] for org in keys(mapping))
    for ((organ_, process_), root_node) in dependency_graph.roots
        traverse_dependency_graph!(root_node) do node
            push!(nodes_ins[node.scale], node.inputs)
            push!(nodes_outs[node.scale], node.outputs)
        end
    end
    ins = Dict(k => flatten_vars(vcat(v...)) for (k, v) in nodes_ins)
    outs = Dict(k => flatten_vars(vcat(v...)) for (k, v) in nodes_outs)

    return Dict(:inputs => ins, :outputs => outs)
end


"""
    variables_outputs_from_other_scale(mapped_vars)

For each organ in the `mapped_vars`, find the variables that are outputs from another scale and not computed at this scale otherwise.
This function is used with mapped_variables
"""
function variables_outputs_from_other_scale(mapped_vars)
    vars_outputs_from_scales = Dict{String,Vector{MappedVar}}()
    # Scale at which we have to add a variable => [(source_process, source_scale, variable), ...]
    for (organ, outs) in mapped_vars[:outputs] # organ = "Plant" ; outs = mapped_vars[:outputs][organ]
        for (var, val) in pairs(outs) # var = :carbon_allocation ; val = outs[1]
            if isa(val, MappedVar)
                orgs = mapped_organ(val)
                orgs_iterable = isa(orgs, AbstractString) ? [orgs] : orgs

                for o in orgs_iterable
                    # The MappedVar can only have one value for the default, because it comes from the computing scale (the source scale):
                    var_default_value = mapped_default(val)

                    if mapped_organ_type(val) == MultiNodeMapping
                        # The variable is written to several organs, the default value must be a vector:
                        if isa(var_default_value, AbstractVector)
                            # Mapping into a vector of organs, the default value must be a vector:
                            @assert length(var_default_value) == 1 "The variable `$(mapped_variable(val))` is an output variable computed by scale `$organ` and written to organs at scale `$(join(mapped_organ(val), ", "))`, " *
                                                                   "but the default value coming from `$organ` is not of length 1: $(var_default_value). " *
                                                                   "Make sure the model that computes this variable at scale `$organ` has a vector of values of length 1 as " *
                                                                   "default outputs for variable `$(mapped_variable(val))`."
                            var_default_value = var_default_value[1]
                        else
                            error(
                                "The variable `$(mapped_variable(val))` is an output variable computed by scale `$organ` and written to organs at scale `$(join(mapped_organ(val), ", "))`, " *
                                "but the default value coming from `$organ` is not of length 1: $(var_default_value). " *
                                "Make sure the model that computes this variable at scale `$organ` has a vector of values of length 1 as " *
                                "default outputs for variable `$(mapped_variable(val))`."
                            )
                        end
                    else
                        # The variables is mapped to a single organ, the default value must be a scalar:
                        @assert !isa(var_default_value, AbstractVector) "The variable `$(mapped_variable(val))` is an output variable computed by scale `$organ` and written to organ at scale `$o`, " *
                                                                        "but the default value coming from `$organ` is a vector: $(var_default_value). " *
                                                                        "Make sure the model that computes this variable at scale `$organ` has a scalar value as " *
                                                                        "default outputs for variable `$(mapped_variable(val))` (*e.g.* $(var_default_value[1])), or update your mapping to map the organ as a vector: " *
                                                                        """`$(mapped_variable(val)) => ["$o"]`."""
                    end
                    # We make a MappedVar object to declare the variable as an input of this scale:
                    mapped_var = MappedVar(
                        SelfNodeMapping(), # The source organ is itself, we just do that so the variable exist in its status
                        source_variable(val, o),
                        source_variable(val, o),
                        var_default_value,
                    )

                    if !haskey(vars_outputs_from_scales, o)
                        vars_outputs_from_scales[o] = [mapped_var]
                    else
                        push!(vars_outputs_from_scales[o], mapped_var)
                    end
                end
            end
        end
    end
    return vars_outputs_from_scales
end


"""
    add_mapped_variables_with_outputs_as_inputs!(mapped_vars)

Add the variables that are computed at a scale and written to another scale into the mapping.
"""
function add_mapped_variables_with_outputs_as_inputs!(mapped_vars)
    # Get the variables computed by a scale and written to another scale (we have to add them as inputs to the "another" scale):
    outputs_written_by_other_scales = variables_outputs_from_other_scale(mapped_vars)

    for (organ, vars) in outputs_written_by_other_scales # organ = "Internode" ; vars = outputs_written_by_other_scales["Internode"]
        if haskey(mapped_vars[:inputs], organ)
            mapped_vars[:inputs][organ] = merge(mapped_vars[:inputs][organ], NamedTuple(mapped_variable(v) => v for v in vars))
        else
            error("The scale $organ is mapped as an output scale from anothe scale, but is not declared in the mapping.")
        end
    end

    return mapped_vars
end


"""
    transform_single_node_mapped_variables_as_self_node_output!(mapped_vars)

Find variables that are inputs to other scales as a `SingleNodeMapping` and declare them as MappedVar from themselves in the source scale.
This helps us declare it as a reference when we create the template status objects.

These node are found in the mapping as `[:variable_name => "Plant"]` (notice that "Plant" is a scalar value).
"""
function transform_single_node_mapped_variables_as_self_node_output!(mapped_vars)
    for (organ, vars) in mapped_vars[:inputs] # e.g. organ = "Leaf"; vars = mapped_vars[:inputs]["Leaf"]
        for (var, mapped_var) in pairs(vars) # e.g. var = :soil_water_content; mapped_var = vars[:soil_water_content]
            if isa(mapped_var, MappedVar{SingleNodeMapping})
                source_organ = mapped_organ(mapped_var)
                @assert source_organ != organ "Variable `$var` is mapped to its own scale in organ $organ. This is not allowed."

                # Transforming the variable into a MappedVar pointing to itself:
                self_mapped_var = (;
                    source_variable(mapped_var) =>
                        MappedVar(
                            SelfNodeMapping(),
                            source_variable(mapped_var),
                            source_variable(mapped_var),
                            mapped_vars[:outputs][source_organ][source_variable(mapped_var)],
                        )
                )
                mapped_vars[:outputs][source_organ] = merge(mapped_vars[:outputs][source_organ], self_mapped_var)
                # Note: merge overwrites the LHS values with the RHS values if they have the same key.
            end
        end
    end

    return mapped_vars
end

"""
    get_multiscale_default_value(mapped_vars, val, mapping_stacktrace=[])

Get the default value of a variable from a mapping.

# Arguments

- `mapped_vars::Dict{String,Dict{Symbol,Any}}`: the variables mapped to each organ.
- `val::Any`: the variable to get the default value of.
- `mapping_stacktrace::Vector{Any}`: the stacktrace of the search for the value in ascendind the mapping.
"""
function get_multiscale_default_value(mapped_vars, val, mapping_stacktrace=[], level=1)
    if isa(val, MappedVar) && !isa(val, MappedVar{SelfNodeMapping})
        # If the value is a MappedVar, we must find the default value of the variable it is mapping into.
        # Except if it is mapping to itself, in which case we return the value as is.
        level += 1
        # Find the default value of the variable from the scale it is mapping into (upper scale):
        m_organ = mapped_organ(val)
        if isa(m_organ, AbstractString)
            m_organ = [m_organ]
        end
        default_vals = []
        for o in m_organ # e.g. o = "Leaf"
            upper_value = mapped_vars[o][source_variable(val, o)]
            push!(mapping_stacktrace, (mapped_organ=o, mapped_variable=source_variable(val, o), mapped_value=mapped_default(upper_value), level=level))
            # Recursively find the default value until the default value is not a MappedVar:
            push!(default_vals, get_multiscale_default_value(mapped_vars, upper_value, mapping_stacktrace, level))
        end

        default_vals = unique(default_vals)
        if length(default_vals) == 1
            return default_vals[1]
        else
            error(
                "The variable `$(mapped_variable(val))` is mapped to several scales: $(m_organ), but the default values from the models that compute ",
                "this variable at these scales is different: $(default_vals). Please make sure that the default values are the same for variable `$(mapped_variable(val))`.",
            )
        end
    elseif isa(val, MappedVar{SelfNodeMapping})
        return mapped_default(val)
    else
        return val
    end
end

"""
    default_variables_from_mapping(mapped_vars, verbose=true)

Get the default values for the mapped variables by recursively searching from the mapping to find the original mapped value.

# Arguments

- `mapped_vars::Dict{String,Dict{Symbol,Any}}`: the variables mapped to each organ.
- `verbose::Bool`: whether to print the stacktrace of the search for the default value in the mapping.
"""
function default_variables_from_mapping(mapped_vars, verbose=true)
    mapped_vars_mutable = Dict{String,Dict{Symbol,Any}}(k => Dict(pairs(v)) for (k, v) in mapped_vars)
    for (organ, vars) in mapped_vars # organ = "Plant"; vars = mapped_vars[organ]
        for (var, val) in pairs(vars) # var = :Rm_organs; val = getproperty(vars,var)
            if isa(val, MappedVar) && !isa(val, MappedVar{SelfNodeMapping})
                mapping_stacktrace = Any[(mapped_organ=organ, mapped_variable=var, mapped_value=mapped_default(mapped_vars[organ][var]), level=1)]
                default_value = get_multiscale_default_value(mapped_vars, val, mapping_stacktrace)
                mapped_vars_mutable[organ][var] = MappedVar(source_organs(val), mapped_variable(val), source_variable(val), default_value)
                if verbose
                    @info """Default value for $(var) in $(organ) is taken from a mapping, here is the stacktrace: """ maxlog = 1

                    @info Term.Tables.Table(Tables.matrix(reverse(mapping_stacktrace)); header=["Scale", "Variable name", "Default value", "Level"])

                    @info """The stacktrace shows the step-by-step search for the default value, the last row is the value starting from the organ itself,
                    and going up to the upper-most model in the dependency graph (first row). The `level` column indicates the level of the search,
                    with 1 being the upper-most model in the dependency graph. The default value is the value found in the first row of the stacktrace,
                    or the unique value between common levels.
                    """ maxlog = 1
                end
            end
        end
    end
    return mapped_vars_mutable
end
