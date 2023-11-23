"""
    hard_dependencies(models; verbose::Bool=true)
    hard_dependencies(mapping::Dict{String,T}; verbose::Bool=true)

Compute the hard dependencies between models.
"""
function hard_dependencies(models; verbose::Bool=true)
    dep_graph = Dict(
        p => HardDependencyNode(
            i,
            p,
            NamedTuple(),
            Int[],
            nothing,
            HardDependencyNode[]
        ) for (p, i) in pairs(models)
    )
    dep_not_found = Dict{Symbol,DataType}()
    for (process, i) in pairs(models) # for each model in the model list
        level_1_dep = dep(i) # we get the dependencies of the model
        length(level_1_dep) == 0 && continue # if there is no dependency we skip the iteration
        dep_graph[process].dependency = level_1_dep
        for (p, depend) in pairs(level_1_dep) # for each dependency of the model i
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

# When we use a mapping (multiscale), we return the set of soft-dependencies (we put the hard-dependencies as their children):
function hard_dependencies(mapping::Dict{String,T}; verbose::Bool=true) where {T}
    full_mapping = Dict(first(mod) => Dict(get_mapping(last(mod))) for mod in mapping)

    soft_dep_graphs = Dict{String,Any}(i => 0.0 for i in keys(mapping))
    not_found = Dict{Symbol,DataType}()
    for (organ, model) in mapping
        # organ = "Leaf"; model = mapping[organ]
        mods = parse_models(get_models(model))

        # Move some models below others when they are manually linked (hard-dependency):
        hard_deps = hard_dependencies((; mods...), verbose=verbose)
        d_vars = Dict{Symbol,Vector{Pair{Symbol,NamedTuple}}}()
        for (procname, node) in hard_deps.roots
            var = Pair{Symbol,NamedTuple}[]
            traverse_dependency_graph!(node, x -> variables_multiscale(x, organ, full_mapping), var)
            push!(d_vars, procname => var)
        end

        inputs_process = Dict{Symbol,Vector{Pair{Symbol,Tuple{Vararg{Union{Symbol,MappedVar}}}}}}(
            key => [j.first => j.second.inputs for j in val] for (key, val) in d_vars
        )
        outputs_process = Dict{Symbol,Vector{Pair{Symbol,Tuple{Vararg{Union{Symbol,MappedVar}}}}}}(
            key => [j.first => j.second.outputs for j in val] for (key, val) in d_vars
        )

        soft_dep_graph = Dict(
            process_ => SoftDependencyNode(
                soft_dep_vars.value,
                process_, # process name
                organ, # scale
                AbstractTrees.children(soft_dep_vars), # hard dependencies
                nothing,
                nothing,
                SoftDependencyNode[],
                [0] # Vector of zeros of length = number of time-steps
            )
            for (process_, soft_dep_vars) in hard_deps.roots
        )

        soft_dep_graphs[organ] = (soft_dep_graph=soft_dep_graph, inputs=inputs_process, outputs=outputs_process)
        not_found = merge(not_found, hard_deps.not_found)
    end

    return DependencyGraph(soft_dep_graphs, not_found)
end