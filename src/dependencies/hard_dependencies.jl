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


# When we use a mapping (multiscale), we return the set of soft-dependencies (we put the hard-dependencies as their children):
function hard_dependencies(mapping::Dict{String,T}; verbose::Bool=true) where {T}
    full_vars_mapping = Dict(first(mod) => Dict(get_mapping(last(mod))) for mod in mapping)
    soft_dep_graphs = Dict{String,Any}()
    not_found = Dict{Symbol,DataType}()

    mods = Dict(organ => parse_models(get_models(model)) for (organ, model) in mapping)

    # For each scale, move the hard-dependency models as children of the its parent model.
    # Note: this is mono-scale at this point (computes each scale independently)  
    # Since the hard dependencies are inserted into the soft dependency graph as children and aren't referenced elsewhere
    # it becomes harder to keep track of them as needed without traversing the graph
    # so keep tabs on them during initialisation until they're no longer needed
    hard_dependency_dict = Dict{Symbol, HardDependencyNode}()
    hard_deps = Dict()
    
    hard_deps = Dict(organ => hard_dependencies(mods_scale, scale=organ, verbose=false) for (organ, mods_scale) in mods)

    # Compute the inputs and outputs of all "root" node of the hard dependencies, so the root 
    # node that takes control over other models appears to have the union of its own inputs (resp. outputs)
    # and the ones from its hard dependencies.
    #* Note that we compute this before computing the multiscale hard dependencies because the inputs/outputs
    #* of hard-dependency models should remain in their own scale. Note that the variables from the hard 
    #* dependency may not appear in its own scale, but this is treated in the soft-dependency computation
    inputs_process = Dict{String,Dict{Symbol,Vector}}()
    outputs_process = Dict{String,Dict{Symbol,Vector}}()
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
            traverse_dependency_graph!(node, x -> variables_multiscale(x, organ, full_vars_mapping, st_scale_user), var)
            push!(status_scale, procname => var)
        end

        inputs_process[organ] = Dict(key => [j.first => j.second.inputs for j in val] for (key, val) in status_scale)
        outputs_process[organ] = Dict(key => [j.first => j.second.outputs for j in val] for (key, val) in status_scale)
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

                # add the new node to the flat list of hard deps, as they aren't trivial to access in the dep graph, and we might need them later for a couple of things
                hard_dependency_dict[p] = new_node

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
                [0] # Vector of zeros of length = number of time-steps
            )
            for (process_, soft_dep_vars) in hard_deps[organ].roots # proc_ = :carbon_assimilation ; soft_dep_vars = hard_deps.roots[proc_]
        )

        # Update the parent node of the hard dependency nodes to be the new SoftDependencyNode instead of the old
        # HardDependencyNode.
        for (p, node) in soft_dep_graph
            for n in node.hard_dependency
                n.parent = node
            end
        end

        soft_dep_graphs[organ] = (soft_dep_graph=soft_dep_graph, inputs=inputs_process[organ], outputs=outputs_process[organ])
        not_found = merge(not_found, hard_deps[organ].not_found)
    end

    return (DependencyGraph(soft_dep_graphs, not_found), hard_dependency_dict)
end