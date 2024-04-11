"""
    traverse_dependency_graph(graph::DependencyGraph, f::Function; visit_hard_dep=true)

Traverse the dependency `graph` and apply the function `f` to each node.
The first-level soft-dependencies are traversed first, then their
hard-dependencies (if `visit_hard_dep=true`), and then the children of the soft-dependencies.

Return a vector of pairs of the node and the result of the function `f`.

# Example

```julia
using PlantSimEngine

# Including example processes and models:
using PlantSimEngine.Examples;

function f(node)
    node.value
end

vars = (
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    process4=Process4Model(),
    process5=Process5Model(),
    process6=Process6Model(),
    process7=Process7Model(),
)

graph = dep(vars)
traverse_dependency_graph(graph, f)
```
"""
function traverse_dependency_graph(
    graph::DependencyGraph,
    f::Function;
    visit_hard_dep=true
)
    var = []
    for (p, root) in graph.roots
        traverse_dependency_graph!(root, f, var; visit_hard_dep=visit_hard_dep)
    end

    return var
end


function traverse_dependency_graph!(
    f::Function,
    node::SoftDependencyNode;
    visit_hard_dep=true
)

    f(node)
    # Traverse the hard dependencies of the SoftDependencyNode if any:
    if visit_hard_dep && node isa SoftDependencyNode
        # draw a branching guide if there's more soft dependencies after this one:
        for child in node.hard_dependency
            traverse_dependency_graph!(f, child)
        end
    end

    for child in node.children
        traverse_dependency_graph!(f, child; visit_hard_dep=visit_hard_dep)
    end
end

function traverse_dependency_graph!(
    f::Function,
    node::HardDependencyNode;
    visit_hard_dep=true
)

    f(node)
    # Traverse all hard dependencies:
    for child in node.children
        traverse_dependency_graph!(f, child)
    end
end


"""
    traverse_dependency_graph(node::SoftDependencyNode, f::Function, var::Vector; visit_hard_dep=true)

Apply function `f` to `node`, visit its hard dependency nodes (if `visit_hard_dep=true`), and 
then its soft dependency children.

Mutate the vector `var` by pushing a pair of the node process name and the result of the function `f`.
"""
function traverse_dependency_graph!(
    node::SoftDependencyNode,
    f::Function,
    var::Vector;
    visit_hard_dep=true
)
    push!(var, node.process => f(node))

    # Traverse the hard dependencies of the SoftDependencyNode if any:
    if visit_hard_dep && node isa SoftDependencyNode
        # draw a branching guide if there's more soft dependencies after this one:
        for child in node.hard_dependency
            traverse_dependency_graph!(child, f, var)
        end
    end

    for child in node.children
        traverse_dependency_graph!(child, f, var; visit_hard_dep=visit_hard_dep)
    end
end

"""
    traverse_dependency_graph(node::HardDependencyNode, f::Function, var::Vector)

Apply function `f` to `node`, and then its children (hard-dependency nodes).

Mutate the vector `var` by pushing a pair of the node process name and the result of the function `f`.
"""
function traverse_dependency_graph!(
    node::HardDependencyNode,
    f::Function,
    var::Vector;
    visit_hard_dep=true  # Just to be compatible with a call shared with SoftDependencyNode method
)
    push!(var, node.process => f(node))

    for child in node.children
        traverse_dependency_graph!(child, f, var)
    end
end
