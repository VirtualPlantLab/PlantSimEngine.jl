
###########################################
# Toy plant model 
# Physiologically meaningless but illustrates organ creation
###########################################

function get_n_leaves(node::MultiScaleTreeGraph.Node)
    root = MultiScaleTreeGraph.get_root(node)
    nleaves = length(MultiScaleTreeGraph.traverse(root, x->1, symbol="Leaf"))
    return nleaves
end

PlantSimEngine.@process "organ_emergence" verbose = false

struct ToyCustomInternodeEmergence <: AbstractOrgan_EmergenceModel
    TT_emergence::Float64
    carbon_internode_creation_cost::Float64
    leaf_surface_area::Float64
    leaves_max_surface_area::Float64
end

ToyCustomInternodeEmergence(;TT_emergence=300.0, carbon_internode_creation_cost=200.0, leaf_surface_area=3.0, leaves_max_surface_area=100.0) = ToyCustomInternodeEmergence(TT_emergence, carbon_internode_creation_cost, leaf_surface_area, leaves_max_surface_area)

PlantSimEngine.inputs_(m::ToyCustomInternodeEmergence) = (TT_cu=0.0, carbon_stock=0.0)
PlantSimEngine.outputs_(m::ToyCustomInternodeEmergence) = (TT_cu_emergence=0.0, carbon_organ_creation_consumed=0.0)

function PlantSimEngine.run!(m::ToyCustomInternodeEmergence, models, status, meteo, constants=nothing, sim_object=nothing)

    leaves_surface_area = m.leaf_surface * get_n_leaves(status.node)
    status.carbon_organ_creation_consumed = 0.0

    if leaves_surface_area > m.leaves_max_surface_area
        return nothing
    end
    
    # if not enough carbon, no organ creation
    if status.carbon_stock < m.carbon_internode_creation_cost
        return nothing
    end
  
    if length(MultiScaleTreeGraph.children(status.node)) == 2 && 
        status.TT_cu - status.TT_cu_emergence >= m.TT_emergence            
        status_new_internode = add_organ!(status.node, sim_object, "<", "Internode", 2, index=1)
        add_organ!(status_new_internode.node, sim_object, "+", "Leaf", 2, index=1)
        add_organ!(status_new_internode.node, sim_object, "+", "Leaf", 2, index=1)

        status_new_internode.TT_cu_emergence = m.TT_emergence - status.TT_cu
        status.carbon_organ_creation_consumed = m.carbon_internode_creation_cost
    end

    return nothing
end

##########################
### Model accumulating carbon resources 
##########################

PlantSimEngine.@process "resource_stock_computation" verbose = false

struct ToyStockComputationModel <: AbstractResource_Stock_ComputationModel
end

PlantSimEngine.inputs_(::ToyStockComputationModel) = 
(carbon_captured=0.0,carbon_organ_creation_consumed=0.0)

PlantSimEngine.outputs_(::ToyStockComputationModel) = (carbon_stock=-Inf,)

function PlantSimEngine.run!(m::ToyStockComputationModel, models, status, meteo, constants=nothing, extra=nothing)
    status.carbon_stock += sum(status.carbon_captured) - sum(status.carbon_organ_creation_consumed)
end

PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyStockComputationModel}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyStockComputationModel}) = PlantSimEngine.IsObjectIndependent()

########################
## Leaf model capturing some arbitrary carbon quantity
########################

PlantSimEngine.@process "leaf_carbon_capture" verbose = false

struct ToyLeafCarbonCaptureModel<: AbstractLeaf_Carbon_CaptureModel end

function PlantSimEngine.inputs_(::ToyLeafCarbonCaptureModel)
    NamedTuple()#(TT_cu=-Inf)
end

function PlantSimEngine.outputs_(::ToyLeafCarbonCaptureModel)
    (carbon_captured=0.0,)
end

function PlantSimEngine.run!(::ToyLeafCarbonCaptureModel, models, status, meteo, constants, extra)   
    # very crude approximation with LAI of 1 and constant PPFD
    status.carbon_captured = 200.0 *(1.0 - exp(-0.2))
end

PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyLeafCarbonCaptureModel}) = PlantSimEngine.IsObjectIndependent()
PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyLeafCarbonCaptureModel}) = PlantSimEngine.IsTimeStepIndependent()

mapping = Dict(
"Scene" => ToyDegreeDaysCumulModel(),
"Plant" => (
    MultiScaleModel(
        model=ToyStockComputationModel(),          
        mapped_variables=[
            :carbon_captured=>["Leaf"],
            :carbon_organ_creation_consumed=>["Internode"]
        ],
        ),
        Status(carbon_stock = 0.0)
    ),
"Internode" => (        
        MultiScaleModel(
            model=ToyCustomInternodeEmergence(),#TT_emergence=20.0),
            mapped_variables=[:TT_cu => "Scene",
            PreviousTimeStep(:carbon_stock)=>"Plant"],
        ),        
        Status(carbon_organ_creation_consumed=0.0),
    ),
"Leaf" => ( ToyLeafCarbonCaptureModel(),),
)

    mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0))   
#MultiScaleTreeGraph.Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Soil", 1, 1))
    plant = MultiScaleTreeGraph.Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))
    
    internode1 = MultiScaleTreeGraph.Node(plant, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    MultiScaleTreeGraph.Node(internode1, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
    MultiScaleTreeGraph.Node(internode1, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))

    internode2 = MultiScaleTreeGraph.Node(internode1, MultiScaleTreeGraph.NodeMTG("<", "Internode", 1, 2))
    MultiScaleTreeGraph.Node(internode2, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
    MultiScaleTreeGraph.Node(internode2, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))


    meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
    
    outs = run!(mtg, mapping, meteo_day)
    mtg

    length(MultiScaleTreeGraph.traverse(mtg,x->x, symbol="Leaf"))

    for i in 1:365
        for j in 1:length(outs["Plant"][:carbon_organ_creation_consumed][i])
        if outs["Plant"][:carbon_organ_creation_consumed][i][1][j] != 0.0
            println(i)
        end
        end
    end