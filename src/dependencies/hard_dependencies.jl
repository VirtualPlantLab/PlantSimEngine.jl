function hard_dependencies(models; verbose::Bool=true)
    dep_tree = Dict(
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
        dep_tree[process].dependency = level_1_dep
        for (p, depend) in pairs(level_1_dep) # for each dependency of the model i
            if hasproperty(models, p)
                if typeof(getfield(models, p)) <: depend
                    parent_dep = dep_tree[process]
                    push!(parent_dep.children, dep_tree[p])
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
                        dep_tree[process].missing_dependency,
                        findfirst(x -> x == p, keys(level_1_dep))
                    ) # index of the missing dep
                    # NB: we can retreive missing deps using dep_tree[process].dependency[dep_tree[process].missing_dependency]
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
                    dep_tree[process].missing_dependency,
                    findfirst(x -> x == p, keys(level_1_dep))
                ) # index of the missing dep
                # NB: we can retreive missing deps using dep_tree[process].dependency[dep_tree[process].missing_dependency]
            end
        end
    end

    roots = [AbstractTrees.getroot(i) for i in values(dep_tree)]
    # Keeping only the trees with no common root nodes, i.e. remove trees that are part of a
    # bigger dependency tree:
    unique_roots = Dict{Symbol,HardDependencyNode}()
    for (p, m) in dep_tree
        if m in roots
            push!(unique_roots, p => m)
        end
    end

    return unique_roots, dep_not_found
end