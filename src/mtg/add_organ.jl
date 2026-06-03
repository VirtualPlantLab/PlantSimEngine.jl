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
* `symbol`: the symbol of the organ, *e.g.* `:Leaf`
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

function _delete_ref_from_refvector!(rv::RefVector, ref)
    filter!(stored_ref -> stored_ref !== ref, parent(rv))
    return rv
end

function _remove_status_from_scale!(statuses::Dict, scale::Symbol, st::Status, nid::Int)
    haskey(statuses, scale) || return nothing
    deleteat!(statuses[scale], findall(candidate -> candidate === st || node_id(candidate.node) == nid, statuses[scale]))
    return nothing
end

function _remove_reverse_refs_for_status!(sim_object, node_scale::Symbol, st::Status)
    haskey(sim_object.reverse_multiscale_mapping, node_scale) || return nothing
    for (target_scale, vars) in sim_object.reverse_multiscale_mapping[node_scale]
        haskey(sim_object.status_templates, target_scale) || continue
        target_template = sim_object.status_templates[target_scale]
        for (source_var, target_var_) in vars
            source_var in propertynames(st) || continue
            target_var = target_var_ isa PreviousTimeStep ? target_var_.variable : target_var_
            haskey(target_template, target_var) || continue
            target_value = target_template[target_var]
            target_value isa RefVector || continue
            _delete_ref_from_refvector!(target_value, refvalue(st, source_var))
        end
    end
    return nothing
end

function _remove_temporal_state_for_node!(sim_object, nid::Int)
    temporal = temporal_state(sim_object)
    for key in collect(keys(temporal.caches))
        key.node_id == nid && delete!(temporal.caches, key)
    end
    for key in collect(keys(temporal.streams))
        key.node_id == nid && delete!(temporal.streams, key)
    end
    return nothing
end

function _status_node_registered(sim_object, node::MultiScaleTreeGraph.Node)
    node_scale = symbol(node)
    haskey(sim_object.statuses, node_scale) || return false
    nid = node_id(node)
    return any(st -> hasproperty(st, :node) && node_id(st.node) == nid && st.node === node, sim_object.statuses[node_scale])
end

function _is_descendant_node(candidate::MultiScaleTreeGraph.Node, ancestor::MultiScaleTreeGraph.Node)
    current = parent(candidate)
    while !isnothing(current)
        current === ancestor && return true
        current = parent(current)
    end
    return false
end

function _children_without_node(parent_node::MultiScaleTreeGraph.Node, node::MultiScaleTreeGraph.Node)
    children_without_node = empty(AbstractTrees.children(parent_node))
    for child in AbstractTrees.children(parent_node)
        child === node || push!(children_without_node, child)
    end
    return children_without_node
end

function _repair_reparent_child_links!(
    node::MultiScaleTreeGraph.Node,
    old_parent,
    new_parent::MultiScaleTreeGraph.Node,
)
    if !isnothing(old_parent) && old_parent !== new_parent
        MultiScaleTreeGraph.rechildren!(old_parent, _children_without_node(old_parent, node))
    end

    new_children = _children_without_node(new_parent, node)
    push!(new_children, node)
    MultiScaleTreeGraph.rechildren!(new_parent, new_children)
    return nothing
end

"""
    remove_organ!(node::MultiScaleTreeGraph.Node, sim_object; attribute_name=:plantsimengine_status, recursive=false)

Remove a simulated organ from an active [`GraphSimulation`](@ref).

The wrapper updates PlantSimEngine runtime state before delegating to
`MultiScaleTreeGraph.delete_node!`: it removes the node status from
`sim_object.statuses`, removes references from downstream `RefVector`s, clears
temporal caches/streams for the removed node, and then deletes the MTG node.

Only leaf/terminal nodes are removed by default. Pass `recursive=true` to delete
an internal node and its whole subtree. Reparenting children is intentionally not
handled here because it requires caller-specific biological and topological
policy.
"""
function remove_organ!(node::MultiScaleTreeGraph.Node, sim_object; attribute_name=:plantsimengine_status, recursive=false)
    children = collect(AbstractTrees.children(node))
    if !recursive
        isempty(children) || error(
            "remove_organ!(...; recursive=false) only supports leaf/terminal MTG nodes. ",
            "Pass `recursive=true` to delete node $(node_id(node)) and its descendants, ",
            "or move descendants first."
        )
    else
        for child in children
            remove_organ!(child, sim_object; attribute_name=attribute_name, recursive=true)
        end
    end

    haskey(node, attribute_name) || error(
        "Cannot remove MTG node $(node_id(node)) ($(symbol(node))) from PlantSimEngine runtime: ",
        "the node has no `$(attribute_name)` status."
    )

    st = node[attribute_name]
    st isa Status || error(
        "Cannot remove MTG node $(node_id(node)) ($(symbol(node))) from PlantSimEngine runtime: ",
        "`$(attribute_name)` is not a Status."
    )

    nid = node_id(node)
    node_scale = symbol(node)
    _remove_reverse_refs_for_status!(sim_object, node_scale, st)
    _remove_status_from_scale!(sim_object.statuses, node_scale, st, nid)
    _remove_temporal_state_for_node!(sim_object, nid)
    pop!(node, attribute_name)
    return MultiScaleTreeGraph.delete_node!(node)
end

"""
    reparent_organ!(node::MultiScaleTreeGraph.Node, new_parent::MultiScaleTreeGraph.Node, sim_object; attribute_name=:plantsimengine_status)

Move an already-simulated MTG node under another already-simulated parent in the
same active [`GraphSimulation`](@ref).

The node status and downstream `RefVector`s keep pointing to the same node
object, so no status rewiring is needed when the subtree remains in the same
simulation. This wrapper validates that both nodes are registered in
PlantSimEngine runtime state and rejects moves that would create a cycle.
"""
function reparent_organ!(
    node::MultiScaleTreeGraph.Node,
    new_parent::MultiScaleTreeGraph.Node,
    sim_object;
    attribute_name=:plantsimengine_status,
)
    node === new_parent && error("Cannot reparent MTG node $(node_id(node)) to itself.")
    _is_descendant_node(new_parent, node) && error(
        "Cannot reparent MTG node $(node_id(node)) under descendant node $(node_id(new_parent)); ",
        "this would create a cycle."
    )
    haskey(node, attribute_name) || error(
        "Cannot reparent MTG node $(node_id(node)) ($(symbol(node))) in PlantSimEngine runtime: ",
        "the node has no `$(attribute_name)` status."
    )
    haskey(new_parent, attribute_name) || error(
        "Cannot reparent MTG node $(node_id(node)) under node $(node_id(new_parent)) ($(symbol(new_parent))) ",
        "in PlantSimEngine runtime: the new parent has no `$(attribute_name)` status."
    )
    _status_node_registered(sim_object, node) || error(
        "Cannot reparent MTG node $(node_id(node)) ($(symbol(node))): ",
        "it is not registered in this GraphSimulation."
    )
    _status_node_registered(sim_object, new_parent) || error(
        "Cannot reparent MTG node $(node_id(node)) under node $(node_id(new_parent)) ($(symbol(new_parent))): ",
        "the new parent is not registered in this GraphSimulation."
    )

    old_parent = parent(node)
    MultiScaleTreeGraph.reparent!(node, new_parent)
    _repair_reparent_child_links!(node, old_parent, new_parent)
    return node
end
