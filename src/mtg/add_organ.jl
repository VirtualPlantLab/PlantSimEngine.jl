"""
    add_organ!(node::MultiScaleTreeGraph.Node, sim_object, link, symbol, index, scale)

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
* `index`: the index of the organ, *e.g.* `1`. The index may be used to easily identify branching order, or growth unit index on the axis. It is different from the node `id` that is unique.
* `scale`: the scale of the organ, *e.g.* `2`.

# Returns 

* `status`: the status of the new node

# Examples

See the `ToyInternodeEmergence` example model from the `Examples` module (also found in the `examples` folder),
or the `test-mtg-dynamic.jl` test file for an example usage.
"""
function add_organ!(node::MultiScaleTreeGraph.Node, sim_object, link, symbol, index, scale)
    new_node = MultiScaleTreeGraph.Node(node, MultiScaleTreeGraph.NodeMTG(link, symbol, index, scale))
    st = PlantSimEngine.init_status!(new_node, sim_object.statuses, sim_object.status_templates, sim_object.map_other_scales, sim_object.var_need_init)

    return st
end