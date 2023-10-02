function multiscale_dep(models, verbose=true)

    mapping = Dict(first(mod) => Dict(PlantSimEngine.get_mapping(last(mod))) for mod in models)
    #! continue here: we have the inputs and outputs variables for each process per scale, and if the variable can 
    #! be found at another scale, it is defined as a MappedVar (variables + mapped scale).
    #! Now what we need to do is to compute the dependency graph for each process each scale, by searching the inputs
    #! of each process in the outputs of its own scale, or the other scales. There are five cases then:
    #! 1. The process has no inputs. It is completely independent.
    #! 2. The process needs inputs from its own scale. We put it as a child of this other process.
    #! 3. The process needs inputs from another scale. We put it as a child of this process at another scale.
    #! 4. The process needs inputs from its own scale and another scale. We put it as a child of both.
    #! 5. The process is a hard dependency of another process (only possible in own scale). In this case it is treated differently (uses the standard method)
    #! Note that in the 5th case, we still need to check if a variable is needed from another scale. In this case, the root node of the 
    #! hard dependency graph is used as a child of the process at the other scale.

    #! How do we do all that? We identify the hard dependencies first. Then we link the inputs/outputs of the hard dependencies roots 
    #! to other scales if needed. Then we transform all these nodes into soft dependencies, that we put into a Dict of Scale => Dict(process => SoftDependencyNode).
    #! Then we traverse all these and we set nodes that need outputs from other nodes as inputs as children/parents.
    #! If a node has no dependency, it is set as a root node and pushed into a new Dict (independant_process_root). This Dict is the dependency graph.

    # First step, get the hard-dependency graph and create SoftDependencyNodes for each hard-dependency root. In other word, we want 
    # only the nodes that are not hard-dependency of other nodes. These nodes are taken as roots for the soft-dependency graph because they
    # are independant.
    soft_dep_graphs = Dict{String,Any}(i => 0.0 for i in keys(models))
    for (organ, model) in models
        # organ = "Leaf"; model = models[organ]
        mods = PlantSimEngine.parse_models(PlantSimEngine.get_models(model))

        # Move some models below others when they are manually linked (hard-dependency):
        hard_deps = PlantSimEngine.hard_dependencies((; mods...), verbose=verbose)
        d_vars = Dict{Symbol,Vector{Pair{Symbol,NamedTuple}}}()
        for (procname, node) in hard_deps.roots
            var = Pair{Symbol,NamedTuple}[]
            PlantSimEngine.traverse_dependency_graph!(node, x -> PlantSimEngine.variables_multiscale(x, organ, mapping), var)
            push!(d_vars, procname => var)
        end

        inputs_process = Dict{Symbol,Vector{Pair{Symbol,Tuple{Vararg{Union{Symbol,PlantSimEngine.MappedVar}}}}}}(
            key => [j.first => j.second.inputs for j in val] for (key, val) in d_vars
        )
        outputs_process = Dict{Symbol,Vector{Pair{Symbol,Tuple{Vararg{Union{Symbol,PlantSimEngine.MappedVar}}}}}}(
            key => [j.first => j.second.outputs for j in val] for (key, val) in d_vars
        )

        soft_dep_graph = Dict(
            process_ => PlantSimEngine.SoftDependencyNode(
                soft_dep_vars.value,
                process_, # process name
                PlantSimEngine.AbstractTrees.children(soft_dep_vars), # hard dependencies
                nothing,
                nothing,
                PlantSimEngine.SoftDependencyNode[],
                [0] # Vector of zeros of length = number of time-steps
            )
            for (process_, soft_dep_vars) in hard_deps.roots
        )

        soft_dep_graphs[organ] = (soft_dep_graph=soft_dep_graph, inputs=inputs_process, outputs=outputs_process)
    end

    # Second step, compute the soft-dependency graph between SoftDependencyNodes computed in the first step. To do so, we search the 
    # inputs of each process into the outputs of the other processes, at the same scale, but also between scales. Then we keep only the
    # nodes that have no soft-dependencies, and we set them as root nodes of the soft-dependency graph. The other nodes are set as children
    # of the nodes that they depend on.
    independant_process_root = Dict{Pair{String,Symbol},PlantSimEngine.SoftDependencyNode}()
    for (organ, (soft_dep_graph, ins, outs)) in soft_dep_graphs # e.g. organ = "Plant"; soft_dep_graph, ins, outs = soft_dep_graphs[organ]
        for (proc, i) in soft_dep_graph
            # proc = :carbon_allocation; i = soft_dep_graph[proc]
            # Search if the process has soft dependencies:
            soft_deps = PlantSimEngine.search_inputs_in_output(proc, ins, outs)

            # Remove the hard dependencies from the soft dependencies:
            soft_deps_not_hard = PlantSimEngine.drop_process(soft_deps, [hd.process for hd in i.hard_dependency])
            # NB: if a node is already a hard dependency of the node, it cannot be a soft dependency

            # Check if the process has soft dependencies at other scales:
            soft_deps_multiscale = PlantSimEngine.search_inputs_in_multiscale_output(proc, organ, ins, soft_dep_graphs)
            # Example output: "Soil" => Dict(:soil_water=>[:soil_water_content]), which means that the variable :soil_water_content
            # is computed by the process :soil_water at the scale "Soil".

            if length(soft_deps_not_hard) == 0 && i.process in keys(hard_deps.roots) && length(soft_deps_multiscale) == 0
                # If the process has no soft (multiscale) dependencies, then it is independant (so it is a root)
                # Note that the process is only independent if it is also a root in the hard-dependency graph
                independant_process_root[organ=>proc] = i
            else
                # If the process has soft dependencies at its scale, add it:
                if length(soft_deps_not_hard) > 0
                    # If the process has soft dependencies, then it is not independant
                    # and we need to add its parent(s) to the node, and the node as a child
                    for (parent_soft_dep, soft_dep_vars) in pairs(soft_deps_not_hard)
                        # parent_soft_dep = :process5; soft_dep_vars = soft_deps[parent_soft_dep]

                        # preventing a cyclic dependency
                        if parent_soft_dep == proc
                            error("Cyclic model dependency detected for process $proc")
                        end

                        # preventing a cyclic dependency: if the parent also has a dependency on the current node:
                        if soft_dep_graph[parent_soft_dep].parent !== nothing && any([i == p for p in soft_dep_graph[parent_soft_dep].parent])
                            error(
                                "Cyclic dependency detected for process $proc:",
                                " $proc depends on $parent_soft_dep, which depends on $proc.",
                                " This is not allowed, but is possible via a hard dependency."
                            )
                        end

                        # preventing a cyclic dependency: if the current node has the parent node as a child:
                        if i.children !== nothing && any([soft_dep_graph[parent_soft_dep] == p for p in i.children])
                            error(
                                "Cyclic dependency detected for process $proc:",
                                " $proc depends on $parent_soft_dep, which depends on $proc.",
                                " This is not allowed, but is possible via a hard dependency."
                            )
                        end

                        # Add the current node as a child of the node on which it depends
                        push!(soft_dep_graph[parent_soft_dep].children, i)

                        # Add the node on which the current node depends as a parent
                        if i.parent === nothing
                            # If the node had no parent already, it is nothing, so we change into a vector
                            i.parent = [soft_dep_graph[parent_soft_dep]]
                        else
                            push!(i.parent, soft_dep_graph[parent_soft_dep])
                        end

                        # Add the soft dependencies (variables) of the parent to the current node
                        i.parent_vars = soft_deps
                    end
                end

                # If the node has soft dependencies at other scales, add it as child of the other scale (and add its parent too):
                if length(soft_deps_multiscale) > 0
                    #! Continue here: add the node as a child of the other scale, and add this other node has its parent.
                    #! Take inspiration from the code above happening at the same scale.
                    #! Note that the node can have both soft dependencies at its own scale and at other scales, but it is not 
                    #! a big deal because in the end we drop the scales and only keep the root soft-dependency nodes.
                    for org in keys(soft_deps_multiscale)
                        # org = "Leaf"
                        for (parent_soft_dep, soft_dep_vars) in soft_deps_multiscale[org]
                            # parent_soft_dep= :photosynthesis; soft_dep_vars = soft_deps_multiscale[org][parent_soft_dep]
                            parent_node = soft_dep_graphs[org][:soft_dep_graph][parent_soft_dep]
                            # preventing a cyclic dependency: if the parent also has a dependency on the current node:
                            if parent_node.parent !== nothing && any([i == p for p in parent_node.parent])
                                error(
                                    "Cyclic dependency detected for process $proc:",
                                    " $proc for organ $organ depends on $parent_soft_dep from organ $org, which depends on the first one",
                                    " This is not allowed, you may need to develop a new process that does the whole computation by itself."
                                )
                            end

                            # preventing a cyclic dependency: if the current node has the parent node as a child:
                            if i.children !== nothing && any([parent_node == p for p in i.children])
                                error(
                                    "Cyclic dependency detected for process $proc:",
                                    " $proc for organ $organ depends on $parent_soft_dep from organ $org, which depends on the first one.",
                                    " This is not allowed, you may need to develop a new process that does the whole computation by itself."
                                )
                            end

                            # Add the current node as a child of the node on which it depends:
                            push!(parent_node.children, i)

                            # Add the node on which the current node depends as a parent
                            if i.parent === nothing
                                # If the node had no parent already, it is nothing, so we change into a vector
                                i.parent = [parent_node]
                            else
                                push!(i.parent, parent_node)
                            end

                            # Add the multiscale soft dependencies variables of the parent to the current node
                            i.parent_vars = NamedTuple(Symbol(k) => NamedTuple(v) for (k, v) in soft_deps_multiscale)
                        end
                    end
                end
                #! To do: make this code work without multiscale mapping, so we have only one code base for both cases. 
                #! Also, put some parts into functions to make the code more readable.
            end
        end
    end

    #! CONTINUE HERE: use the multiscale variables to compute the dependency graph. The steps would look something like:
    #! 1. Get the hard-dependency graph
    #! 2. Get the soft-dependency graph: do as before by computing inputs and outputs for each hard-dependency root,
    #!    but also look at the multiscale variables to the inputs and outputs.
    #! 3. For each soft-dependency root, check if the process is independant (i.e. if it has no soft-dependencies).
    #!    within its own scale, but also in other scales. If it is independant, then it is a root of the soft-dependency multiscale graph.
    #!    If it is not, then add it as a child of the other soft-dependency node that it depends on.
end