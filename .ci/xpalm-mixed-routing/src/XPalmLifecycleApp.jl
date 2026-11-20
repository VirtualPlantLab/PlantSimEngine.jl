Base.generating_output(true) && __precompile__(false)
module XPalmLifecycleApp
import PlantSimEngine as PSE
const MTG = PSE.MultiScaleTreeGraph
function prepare()
    root = MTG.Node(1, MTG.NodeMTG(:/, :Plant, 1, 1), (note="plot",))
    MTG.add_column!(root, :Plant, :fieldnote, String; default="plot")
    MTG.add_column!(root, :Leaf, :kind, Int; default=3)
    MTG.add_column!(root, :Flower, :kind, Symbol; default=:mature)
    MTG.add_column!(root, :Plant, :quality, Missing; default=missing)
    model = PSE._with_object_id_domain(PSE.CompositeModel(root), PSE.ObjectId{Int})
    MTG.add_column!(root, :Bud, :kind, String; default="dormant")
    MTG.add_column!(root,:Seed,:kind,Missing;default=missing)
    return model
end
const MODEL = prepare()
function (@main)(args)
    root = PSE.source_node(MODEL, 1)
    leaf = PSE.add_organ!(root, MODEL, :+, :Leaf, 2)
    PSE.model_object(MODEL, PSE.source_node(MODEL, leaf)).kind === Symbol(3) || return Cint(1)
    flower = PSE.add_organ!(root, MODEL, :+, :Flower, 2)
    PSE.model_object(MODEL, PSE.source_node(MODEL, flower)).kind === :mature || return Cint(2)
    try
        PSE.add_organ!(root, MODEL, :+, :Bud, 2)
        return Cint(3)
    catch err
        err isa ArgumentError || rethrow()
    end
    isnothing(MTG.get_node(root, 4)) || return Cint(4)
    bud = PSE.add_organ!(root, MODEL, :+, :Bud, 2; attributes=(kind="new",))
    node = PSE.source_node(MODEL, bud)
    MTG.node_id(node) == 4 && PSE.model_object(MODEL, node).kind === :new || return Cint(5)
    try
        PSE.add_organ!(root, MODEL, :+, :Seed, 2)
        return Cint(6)
    catch err
        err isa ArgumentError || rethrow()
    end
    isnothing(MTG.get_node(root, 5)) || return Cint(7)
    return Cint(0)
end
end
