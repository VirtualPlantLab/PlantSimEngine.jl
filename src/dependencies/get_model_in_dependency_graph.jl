"""
    get_model_nodes(dep_graph::DependencyGraph, model)

Get the nodes in the dependency graph implementing a type of model.

# Arguments

- `dep_graph::DependencyGraph`: the dependency graph.
- `model`: the model type to look for.

# Returns

- An array of nodes implementing the model type.

# Examples

```julia
PlantSimEngine.get_model_nodes(dependency_graph, Beer)
```
"""
function get_model_nodes(dep_graph::DependencyGraph, model)
    model_node = Union{SoftDependencyNode,HardDependencyNode}[]

    traverse_dependency_graph!(dep_graph) do node
        if isa(node.value, model)
            push!(model_node, node)
        end
    end

    return model_node
end

function get_model_nodes(dep_graph::DependencyGraph, process::Symbol)
    process_node = Union{SoftDependencyNode,HardDependencyNode}[]

    traverse_dependency_graph!(dep_graph) do node
        if node.process == process
            push!(process_node, node)
        end
    end

    return process_node
end