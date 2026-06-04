function get_root_end_node(node::MultiScaleTreeGraph.Node)
    root = MultiScaleTreeGraph.get_root(node)
    return MultiScaleTreeGraph.traverse(root, x -> x, symbol=:Root, filter_fun=MultiScaleTreeGraph.isleaf)
end

function get_roots_count(node::MultiScaleTreeGraph.Node)
    root = MultiScaleTreeGraph.get_root(node)
    return length(MultiScaleTreeGraph.traverse(root, x -> x, symbol=:Root))
end

function get_n_leaves(node::MultiScaleTreeGraph.Node)
    root = MultiScaleTreeGraph.get_root(node)
    return length(MultiScaleTreeGraph.traverse(root, x -> 1, symbol=:Leaf))
end
