"""
    hard_dependencies(models; verbose::Bool=true)
    hard_dependencies(mapping::Dict{String,T}; verbose::Bool=true)

Compute the hard dependencies between models.
"""
function hard_dependencies(models; scale="", verbose::Bool=true)
    dep_graph = initialise_all_as_hard_dependency_node(models, scale)
    dep_not_found = Dict{Symbol,Any}()
    for (process, i) in pairs(models) # for each model in the model list. process=:state; i=pairs(models)[process]
        level_1_dep = dep(i) # we get the required types for the model dependencies
        length(level_1_dep) == 0 && continue # if there is no dependency we skip the iteration
        dep_graph[process].dependency = level_1_dep
        for (p, depend) in pairs(level_1_dep) # for each dependency of the model i. p=:leaf_rank; depend=pairs(level_1_dep)[p]
            # The dependency can be given as multiscale, e.g. `leaf_area=AbstractLeaf_AreaModel => [m.leaf_symbol],`
            # This means we should search this model in another scale. This is not done here, but after the call to this 
            # function in the other method for `hard_dependencies` below.
            if isa(depend, Pair) 
                if scale != ""
                    # We skip this hard-dependency if it is multiscale, we compute this afterwards in this case
                    push!(dep_not_found, p => (parent_process=process, type=first(depend), scales=last(depend)))
                    continue
                else
                    # If we are not in a multi-scale setup e.g. in a ModelList, we shouldn't use a multiscale model.
                    # But we still authorize it with a warning, and then proceed searching the dependency in this model list.
                    verbose && @warn "Model $i has a multiscale hard dependency on $(first(depend)): $depend. Trying to find the model in this scale instead."
                    depend = first(depend)
                end
            end

            if hasproperty(models, p)
                if typeof(getfield(models, p)) <: depend
                    parent_dep = dep_graph[process]
                    push!(parent_dep.children, dep_graph[p])
                    for child in parent_dep.children
                        child.parent = parent_dep
                    end
                else
                    if verbose
                        @info string(
                            "Model ", typeof(i).name.name, " from process ", process,
                            scale == "" ? "" : " at scale $scale",
                            " needs a model that is a subtype of ", depend, " in process ",
                            p
                        )
                    end

                    push!(dep_not_found, p => depend)

                    push!(
                        dep_graph[process].missing_dependency,
                        findfirst(x -> x == p, keys(level_1_dep))
                    ) # index of the missing dep
                    # NB: we can retreive missing deps using dep_graph[process].dependency[dep_graph[process].missing_dependency]
                end
            else
                if verbose
                    @info string(
                        "Model ", typeof(i).name.name, " from process ", process,
                        scale == "" ? "" : " at scale $scale",
                        " needs a model that is a subtype of ", depend, " in process ",
                        p, ", but the process is not parameterized in the ModelList."
                    )
                end
                push!(dep_not_found, p => depend)

                push!(
                    dep_graph[process].missing_dependency,
                    findfirst(x -> x == p, keys(level_1_dep))
                ) # index of the missing dep
                # NB: we can retreive missing deps using dep_graph[process].dependency[dep_graph[process].missing_dependency]
            end
        end
    end

    roots = [AbstractTrees.getroot(i) for i in values(dep_graph)]
    # Keeping only the graphs with no common root nodes, i.e. remove graphs that are part of a
    # bigger dependency graph:
    unique_roots = Dict{Symbol,HardDependencyNode}()
    for (p, m) in dep_graph
        if m in roots
            push!(unique_roots, p => m)
        end
    end

    return DependencyGraph(unique_roots, dep_not_found)
end

"""
    initialise_all_as_hard_dependency_node(models)

Take a set of models and initialise them all as a hard dependency node, and 
return a dictionary of `:process => HardDependencyNode`.
"""
function initialise_all_as_hard_dependency_node(models, scale)
    dep_graph = Dict(
        p => HardDependencyNode(
            i,
            p,
            NamedTuple(),
            Int[],
            scale,
            inputs_(i),
            outputs_(i),
            nothing,
            HardDependencyNode[]
        ) for (p, i) in pairs(models)
    )

    return dep_graph
end

# Samuel : this requires the orchestrator, which requires the dependency graph
# Leaving it in dependency_graph.jl causes forward declaration issues, moving it here as a quick protoyping hack, it might not be the ideal spot
"""
    variables_multiscale(node, organ, mapping, st=NamedTuple())

Get the variables of a HardDependencyNode, taking into account the multiscale mapping, *i.e.*
defining variables as `MappedVar` if they are mapped to another scale. The default values are 
taken from the model if not given by the user (`st`), and are marked as `UninitializedVar` if 
they are inputs of the node.

Return a NamedTuple with the variables and their default values.

# Arguments

- `node::HardDependencyNode`: the node to get the variables from.
- `organ::String`: the organ type, *e.g.* "Leaf".
- `vars_mapping::Dict{String,T}`: the mapping of the models (see details below).
- `st::NamedTuple`: an optional named tuple with default values for the variables.

# Details

The `vars_mapping` is a dictionary with the organ type as key and a dictionary as value. It is 
computed from the user mapping like so:
"""
function variables_multiscale(node, organ, vars_mapping, st=NamedTuple(), orchestrator::Orchestrator=Orchestrator())
    node_vars = variables(node) # e.g. (inputs = (:var1=-Inf, :var2=-Inf), outputs = (:var3=-Inf,))
    ins = node_vars.inputs
    ins_variables = keys(ins)
    outs_variables = keys(node_vars.outputs)
    defaults = merge(node_vars...)
    map((inputs=ins_variables, outputs=outs_variables)) do vars # Map over vars from :inputs and vars from :outputs
        vars_ = Vector{Pair{Symbol,Any}}()
        for var in vars # e.g. var = :carbon_biomass
            if var in keys(st)
                #If the user has given a status, we use it as default value.
                default = st[var]
            elseif var in ins_variables
                # Otherwise, we use the default value given by the model:
                # If the variable is an input, we mark it as uninitialized:
                default = UninitializedVar(var, defaults[var])
            else
                # If the variable is an output, we use the default value given by the model:
                default = defaults[var]
            end
            if haskey(vars_mapping[organ], var)
                organ_mapped, organ_mapped_var = _node_mapping(vars_mapping[organ][var])
                push!(vars_, var => MappedVar(organ_mapped, var, organ_mapped_var, default))
                #* We still check if the variable also exists wrapped in PreviousTimeStep, because one model could use the current 
                #* values, and another one the previous values.
                if haskey(vars_mapping[organ], PreviousTimeStep(var, node.process))
                    organ_mapped, organ_mapped_var = _node_mapping(vars_mapping[organ][PreviousTimeStep(var, node.process)])
                    push!(vars_, var => MappedVar(organ_mapped, PreviousTimeStep(var, node.process), organ_mapped_var, default))
                end
            elseif haskey(vars_mapping[organ], PreviousTimeStep(var, node.process))
                # If not found in the current time step, we check if the variable is mapped to the previous time step:
                organ_mapped, organ_mapped_var = _node_mapping(vars_mapping[organ][PreviousTimeStep(var, node.process)])
                push!(vars_, var => MappedVar(organ_mapped, PreviousTimeStep(var, node.process), organ_mapped_var, default))
            else
                # Else we take the default value:
                push!(vars_, var => default)
            end
        end
#        end
        return (; vars_...,)
    end
end

function _node_mapping(var_mapping::Pair{String,Symbol})
    # One organ is mapped to the variable:
    return SingleNodeMapping(first(var_mapping)), last(var_mapping)
end

function _node_mapping(var_mapping)
    # Several organs are mapped to the variable:
    organ_mapped = MultiNodeMapping([first(i) for i in var_mapping])
    organ_mapped_var = [last(i) for i in var_mapping]

    return organ_mapped, organ_mapped_var
end

function extract_timestep_mapped_outputs(m::MultiScaleModel, organ::String, outputs_process, timestep_mapped_outputs_process)
    if length(m.timestep_mapped_variables) > 0
        if !haskey(timestep_mapped_outputs_process, organ)
            timestep_mapped_outputs_process[organ] = Dict{Symbol,Vector}()
        end
        key = process(m.model)
        extra_outputs = timestep_mapped_outputs_(m)
        timestep_mapped_outputs_process[organ][key] = extra_outputs
    end
end

# When we use a mapping (multiscale), we return the set of soft-dependencies (we put the hard-dependencies as their children):
function hard_dependencies(mapping::Dict{String,T}; verbose::Bool=true, orchestrator::Orchestrator=Orchestrator()) where {T}
    full_vars_mapping = Dict(first(mod) => Dict(get_mapped_variables(last(mod))) for mod in mapping)
    soft_dep_graphs = Dict{String,Any}()
    not_found = Dict{Symbol,DataType}()

    mods = Dict(organ => parse_models(get_models(model)) for (organ, model) in mapping)

    # For each scale, move the hard-dependency models as children of the its parent model.
    # Note: this is mono-scale at this point (computes each scale independently)  
    # Since the hard dependencies are inserted into the soft dependency graph as children and aren't referenced elsewhere
    # it becomes harder to keep track of them as needed without traversing the graph
    # so keep tabs on them during initialisation until they're no longer needed
    hard_dependency_dict = Dict{Pair{Symbol, String}, HardDependencyNode}()
    
    hard_deps = Dict(organ => hard_dependencies(mods_scale, scale=organ, verbose=false) for (organ, mods_scale) in mods)

    # Compute the inputs and outputs of all "root" node of the hard dependencies, so the root 
    # node that takes control over other models appears to have the union of its own inputs (resp. outputs)
    # and the ones from its hard dependencies.
    #* Note that we compute this before computing the multiscale hard dependencies because the inputs/outputs
    #* of hard-dependency models should remain in their own scale. Note that the variables from the hard 
    #* dependency may not appear in its own scale, but this is treated in the soft-dependency computation
    inputs_process = Dict{String,Dict{Symbol,Vector}}()
    outputs_process = Dict{String,Dict{Symbol,Vector}}()
    timestep_mapped_outputs_process = Dict{String,Dict{Symbol,Vector}}()
    for (organ, model) in mapping
        # Get the status given by the user, that is used to set the default values of the variables in the mapping:
        st_scale_user = get_status(model)
        if isnothing(st_scale_user)
            st_scale_user = NamedTuple()
        else
            st_scale_user = NamedTuple(st_scale_user)
        end

        status_scale = Dict{Symbol,Vector{Pair{Symbol,NamedTuple}}}()
        for (procname, node) in hard_deps[organ].roots # procname = :leaf_surface ; node = hard_deps.roots[procname]
            var = Pair{Symbol,NamedTuple}[]
            traverse_dependency_graph!(node, x -> variables_multiscale(x, organ, full_vars_mapping, st_scale_user, orchestrator), var)
            push!(status_scale, procname => var)
        end

        inputs_process[organ] = Dict(key => [j.first => j.second.inputs for j in val] for (key, val) in status_scale)
        outputs_process[organ] = Dict(key => [j.first => j.second.outputs for j in val] for (key, val) in status_scale)

        # Samuel : This if else loop is a bit awkward
        # None of the other code works this way, it uses the dependency grpah
        # but the hard_dep graph loses the multiscale model information...
        if isa(model, AbstractModel)            
        elseif isa(model, MultiScaleModel)
            extract_timestep_mapped_outputs(model, organ, outputs_process, timestep_mapped_outputs_process)            
        else
            for m in model
                if isa(m, MultiScaleModel)
                    extract_timestep_mapped_outputs(m, organ, outputs_process, timestep_mapped_outputs_process)
                end
            end
        end

        #=for m in model
            if isa(m, MultiScaleModel)
                if length(m.timestep_mapped_variables) > 0
                    key = process(m.model)
                    extra_outputs = timestep_mapped_outputs_(m)
                    ind = findfirst(x -> first(x) == key, outputs_process[organ][key])
                    outputs_process[organ][key][ind] = first(outputs_process[organ][key][ind]) => (; last(outputs_process[organ][key][ind])..., extra_outputs...)

                end
            end
        end=#
    end

    # If some models needed as hard-dependency are not found in their own scale, check the other scales:
    for (organ, model) in mapping
        # organ = "Plant"; model = mapping[organ]
        # filtering the hard dependency that were defined as multiscale (NamedTuple with information)
        multiscale_hard_dep = filter(x -> isa(last(x), NamedTuple), hard_deps[organ].not_found)
        for (p, (parent_process, model_type, scales)) in multiscale_hard_dep
            # debug: p = :initiation_age; parent_process, model_type, scales = multiscale_hard_dep[p]
            parent_node = get_model_nodes(hard_deps[organ], parent_process)
            if length(parent_node) == 0
                continue
            end
            parent_node = only(parent_node)
            # The parent node is the one that needs the hard dependency we are searching
            is_found = Ref(false) # Flag to check if the model was found in the other scales
            for s in scales # s="Phytomer"
                dep_node_model = filter(x -> x.scale == s, get_model_nodes(hard_deps[s], p))
                # Note: here we apply a filter because we modify the graph dynamically, and sometimes
                # we have already computed multiscale hard-dependencies, which can show up here,
                # so we only keep the models that were declared at the scale we are looking.

                if length(dep_node_model) > 0
                    is_found[] = true
                else
                    error("Model `$(typeof(parent_node.value))` from scale $organ requires a model of type `$model_type` at scale $s as a hard dependency, but no model was found for this process.")
                end
                dep_node_model = only(dep_node_model)

                if !isa(dep_node_model.value, model_type)
                    error("Model `$(typeof(parent_node.value))` from scale $organ requires a model of type `$model_type` at scale $s as a hard dependency, but the model found for this process is of type $(typeof(dep_node_model.value)).")
                end

                # We make a new node out of the previous one:
               new_node = HardDependencyNode(
                    dep_node_model.value,
                    dep_node_model.process,
                    dep_node_model.dependency,
                    dep_node_model.missing_dependency,
                    dep_node_model.scale,
                    dep_node_model.inputs,
                    dep_node_model.outputs,
                    parent_node,
                    dep_node_model.children
                )
                
                # Add our new node as a child of the parent node (the one that requires it as a hard dependency)
                push!(parent_node.children, new_node)

                # previously created nested hard dependency nodes' ancestors that have the new_node model as their caller now point to an outdated parent 
                # (and hard dependency node in an outdated state), so their grandparent when traversing upwards might incorrectly be set to nothing
                # update their parent to the correct new node
                for ((hd_sym, hd_scale), hd_node) in hard_dependency_dict

                    if (hd_node.parent.process == p) && (hd_node.scale == hd_scale)
                        hd_node.parent = new_node
                    end
                end

                # add the new node to the flat list of hard deps, as they aren't trivial to access in the dep graph, and we might need them later for a couple of things
                hard_dependency_dict[Pair(p, new_node.scale)] = new_node

                # If it was a root node, we delete it as a root node.
                if dep_node_model in values(hard_deps[s].roots)
                    delete!(hard_deps[s].roots, p) # We delete the value that has the process as key
                end
            end
            # If the model was found in at least one another scale, delete it from the not_found Dict
            is_found[] && delete!(hard_deps[organ].not_found, p)
        end
    end

    for (organ, model) in mapping
        soft_dep_graph = Dict(
            process_ => SoftDependencyNode(
                soft_dep_vars.value,
                process_, # process name
                organ, # scale
                inputs_process[organ][process_], # These are the inputs, potentially multiscale
                outputs_process[organ][process_], # Same for outputs
                AbstractTrees.children(soft_dep_vars), # hard dependencies
                nothing,
                nothing,
                SoftDependencyNode[],
                [0], # Vector of zeros of length = number of time-steps
                orchestrator.default_timestep,
                nothing
            )
            for (process_, soft_dep_vars) in hard_deps[organ].roots # proc_ = :carbon_assimilation ; soft_dep_vars = hard_deps.roots[proc_]
        )
        for (process_, soft_dep_vars) in hard_deps[organ].roots 
             # TODO this is not good enough for some model ranges, and doesn't check for inconsistencies errors for models that have a modeltimestepmapping 
            if timestep_range_(soft_dep_vars.value).lower_bound == timestep_range_(soft_dep_vars.value).upper_bound
                timestep = timestep_range_(soft_dep_vars.value).lower_bound
                
                # if the model has infinite range, set it to the simulation timestep
                if timestep == Second(0)
                    timestep = orchestrator.default_timestep
                end
                soft_dep_graph[process_].timestep = timestep
            end
        end
        # Update the parent node of the hard dependency nodes to be the new SoftDependencyNode instead of the old
        # HardDependencyNode.
        for (p, node) in soft_dep_graph
            for n in node.hard_dependency
                n.parent = node
            end
        end

        soft_dep_graphs[organ] = (soft_dep_graph=soft_dep_graph, inputs=inputs_process[organ], outputs=outputs_process[organ], timestep_mapped_outputs=haskey(timestep_mapped_outputs_process,organ) ? timestep_mapped_outputs_process[organ] : Dict{Symbol,Vector}())
        not_found = merge(not_found, hard_deps[organ].not_found)
    end

    return (DependencyGraph(soft_dep_graphs, not_found), hard_dependency_dict)
end