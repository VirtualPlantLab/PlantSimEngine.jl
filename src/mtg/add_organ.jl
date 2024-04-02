"""
    add_organ!(node::MultiScaleTreeGraph.Node, sim_object, link, symbol, scale; index=0, id=MultiScaleTreeGraph.new_id(MultiScaleTreeGraph.get_root(node)), attributes=Dict{Symbol,Any}(), check=true)

Add an organ to the graph, automatically taking care of initialising the status of the organ (multiscale-)variables.

This function should be called from a model that implements organ emergence, for example in function of thermal time.
 
# Arguments

* `node`: the node to which the organ is added (the parent organ of the new organ)
* `sim_object`: the simulation object, e.g. the `GraphSimulation` object from the `extra` argument of a model.
* `link`: the link type between the new node and the organ:
    * `"<"`: the new node is following the parent organ
    * `"+"`: the new node is branching the parent organ
    * `"/"`: the new node is decomposing the parent organ, *i.e.* we change scale
* `symbol`: the symbol of the organ, *e.g.* `"Leaf"`
* `scale`: the scale of the organ, *e.g.* `2`.
* `index`: the index of the organ, *e.g.* `1`. The index may be used to easily identify branching order, or growth unit index on the axis. It is different from the node `id` that is unique.
* `id`: the unique id of the new node. If not provided, a new id is generated.
* `attributes`: the attributes of the new node. If not provided, an empty dictionary is used.
* `check`: a boolean indicating if variables initialisation should be checked. Passed to `init_node_status!`.

# Returns 

* `status`: the status of the new node

# Examples

See the `ToyInternodeEmergence` example model from the `Examples` module (also found in the `examples` folder),
or the `test-mtg-dynamic.jl` test file for an example usage.
"""
function add_organ!(node::MultiScaleTreeGraph.Node, sim_object, link, symbol, scale; index=0, id=MultiScaleTreeGraph.new_id(MultiScaleTreeGraph.get_root(node)), attributes=Dict{Symbol,Any}(), check=true)
    new_node = MultiScaleTreeGraph.Node(id, node, MultiScaleTreeGraph.NodeMTG(link, symbol, index, scale), attributes)
    st = init_node_status!(new_node, sim_object.statuses, sim_object.status_templates, sim_object.reverse_multiscale_mapping, sim_object.var_need_init, check=check)

    return st
end