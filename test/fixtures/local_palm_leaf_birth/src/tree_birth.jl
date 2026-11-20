# This grows the source tree and the PSE registry in the same transaction.
const MTG = PSE.MultiScaleTreeGraph

function prepare_tree_birth()
    root = MTG.Node(1, MTG.NodeMTG(:/, :Plant, 1, 1),
        (age=0, parameters=Dict{String,Any}("leaf" => [1, 2]),))
    edits = MTG.prepare_node_edits(root)
    kind(node) = MTG.attribute(edits, node, :kind, nothing)::Union{Int,Nothing}
    species(node) = MTG.attribute(edits, node, :species, nothing)::Nothing
    name(node) = MTG.attribute(edits, node, :name, nothing)::Nothing
    model = PSE.CompositeModel(root; kind, species, name)
    return PSE._with_object_id_domain(model, PSE.ObjectId{Int})
end

const TREE_BIRTH = isdefined(MTG, :prepare_node_edits) ? prepare_tree_birth() : nothing

function check_tree_birth!(model)
    root = PSE.source_node(model, 1)
    try
        PSE.add_organ!(root, model, :+, :Leaf, 2; initial_status=(undeclared=4,))
        return false
    catch err
        err isa ArgumentError || rethrow()
    end
    isempty(MTG.children(root)) && isnothing(MTG.get_node(root, 2)) || return false
    first_leaf = PSE.add_organ!(root, model, :+, :Leaf, 2)
    first_node = PSE.source_node(model, first_leaf)
    MTG.node_id(first_node) == 2 && PSE.model_status(model, 2) === first_leaf || return false
    new_leaf = PSE.add_organ!(first_node, model, :+, :Leaf, 2; attributes=(kind=3,))
    new_node = PSE.source_node(model, new_leaf)
    MTG.parent(new_node) === first_node && MTG.node_id(new_node) == 3 || return false
    PSE.model_object(model, new_node).kind === Symbol(3) || return false
    last_leaf = PSE.add_organ!(root, model, :+, :Leaf, 2)
    return isnothing(PSE.model_object(model, PSE.source_node(model, last_leaf)).kind)
end
