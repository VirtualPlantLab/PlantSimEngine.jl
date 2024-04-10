"""
    is_graph_cyclic(dependency_graph::DependencyGraph; full_stack=false, verbose=true)

Check if the dependency graph is cyclic.

# Arguments

- `dependency_graph::DependencyGraph`: the dependency graph to check.
- `full_stack::Bool=false`: if `true`, return the full stack of nodes that makes the cycle, otherwise return only the cycle.
- `warn::Bool=true`: if `true`, print a stylised warning message when a cycle is detected.

Return a boolean indicating if the graph is cyclic, and the stack of nodes as a vector.
"""
function is_graph_cyclic(dependency_graph::DependencyGraph; full_stack=false, warn=true)
    visited = Dict{Pair{AbstractModel,String},Bool}()
    recursion_stack = Dict{Pair{AbstractModel,String},Bool}()
    for node in values(dependency_graph.roots)
        visited[node.value=>node.scale] = false
        recursion_stack[node.value=>node.scale] = false
    end

    for (root, node) in dependency_graph.roots
        cycle_vec = Vector{Pair{AbstractModel,String}}()
        if is_graph_cyclic_(node, visited, recursion_stack, cycle_vec)

            if full_stack
                push!(cycle_vec, node.value => node.scale)
            else
                # Keep just the cycle (the first node in the vector is the one that makes a cycle, we just detect the second time it happens on the stack):
                cycled_nodes = findall(x -> x == cycle_vec[1], cycle_vec)
                cycle_vec = cycle_vec[1:cycled_nodes[2]]
            end

            warn && @warn "Cyclic dependency detected in the graph: \n $(print_cycle(cycle_vec))"

            return true, cycle_vec
        end
    end

    return false, visited
end

function print_cycle(cycle_vec)
    printed_cycle = Any[Term.RenderableText(string("{bold red}", last(cycle_vec[1]), ": ", typeof(first(cycle_vec[1]))))]
    leading_space = [1]
    for (m, s) in cycle_vec[2:end]
        node_print = string(repeat(" ", leading_space[1]), "└ ", s, ": ", typeof(m))
        if (m => s) == cycle_vec[1]
            node_print = Term.RenderableText("{bold red}$node_print")
        else
            node_print = Term.RenderableText(node_print)
        end

        push!(printed_cycle, node_print)
        leading_space[1] += 1
    end

    return join(printed_cycle, "")
end