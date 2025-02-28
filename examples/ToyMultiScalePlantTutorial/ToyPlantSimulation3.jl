###########################################
# Toy plant model with an updated decision model for organ growth
# Physiologically and physically completely meaningless 
# (no dimension for units, arbitrary values, stores water and carbon in abstract stocks,
#  arbitrary max leaf count and root length, constant and non-coupled photosynthesis and water absorption, ...)
# But it should illustrate the basics of simulating a growing multiscale plant with PlantSimEngine's model approach
###########################################

function get_root_end_node(node::MultiScaleTreeGraph.Node)
    root = MultiScaleTreeGraph.get_root(node)
    return MultiScaleTreeGraph.traverse(root, x->x, symbol="Root", filter_fun = MultiScaleTreeGraph.isleaf)
end

function get_roots_count(node::MultiScaleTreeGraph.Node)
    root = MultiScaleTreeGraph.get_root(node)
    return length(MultiScaleTreeGraph.traverse(root, x->x, symbol="Root"))
end

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
    water_leaf_threshold::Float64
end

ToyCustomInternodeEmergence(;TT_emergence=300.0, carbon_internode_creation_cost=200.0, leaf_surface_area=3.0,leaves_max_surface_area=100.0,
water_leaf_threshold=30.0) = ToyCustomInternodeEmergence(TT_emergence, carbon_internode_creation_cost, leaf_surface_area, leaves_max_surface_area, water_leaf_threshold)

PlantSimEngine.inputs_(m::ToyCustomInternodeEmergence) = (TT_cu=0.0,water_stock=0.0, carbon_stock=0.0, carbon_root_creation_consumed=0.0)
PlantSimEngine.outputs_(m::ToyCustomInternodeEmergence) = (TT_cu_emergence=0.0, carbon_organ_creation_consumed=0.0)

function PlantSimEngine.run!(m::ToyCustomInternodeEmergence, models, status, meteo, constants=nothing, sim_object=nothing)

    leaves_surface_area = m.leaf_surface_area * get_n_leaves(status.node)
    status.carbon_organ_creation_consumed = 0.0

    if leaves_surface_area > m.leaves_max_surface_area
        return nothing
    end
    
    # if water levels are low, prioritise roots
    if status.water_stock < m.water_leaf_threshold
        return nothing
    end

    # take into account that the stock may already be depleted 
    carbon_stock_updated_after_roots = status.carbon_stock - status.carbon_root_creation_consumed

    # if not enough carbon, no organ creation
    if carbon_stock_updated_after_roots < m.carbon_internode_creation_cost
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

############################
# Naive water absorption model
# Absorbs precipitation water depending on quantity of roots 
############################
PlantSimEngine.@process "water_absorption" verbose = false

struct ToyWaterAbsorptionModel <: AbstractWater_AbsorptionModel
end

PlantSimEngine.inputs_(::ToyWaterAbsorptionModel) = (root_water_assimilation=1.0,)
PlantSimEngine.outputs_(::ToyWaterAbsorptionModel) = (water_absorbed=0.0,)

function PlantSimEngine.run!(m::ToyWaterAbsorptionModel, models, status, meteo, constants=nothing, extra=nothing)
    #root_end = get_root_end_node(status.node)
    #root_len = root_end[:Root_len]
    status.water_absorbed = meteo.Precipitations * status.root_water_assimilation #* root_len
end

PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyWaterAbsorptionModel}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyWaterAbsorptionModel}) = PlantSimEngine.IsObjectIndependent()


##########################
### Root growth : when water stocks are low, expand root
##########################

PlantSimEngine.@process "root_growth" verbose = false

struct ToyRootGrowthModel <: AbstractRoot_GrowthModel
    carbon_root_creation_cost
    root_max_len::Int
end

PlantSimEngine.inputs_(::ToyRootGrowthModel) = NamedTuple()
PlantSimEngine.outputs_(::ToyRootGrowthModel) = (carbon_root_creation_consumed=0.0,)

function PlantSimEngine.run!(m::ToyRootGrowthModel, models, status, meteo, constants=nothing, extra=nothing)    
    status.carbon_root_creation_consumed = 0.0

    root_end = get_root_end_node(status.node)
        
    if length(root_end) != 1 
        throw(AssertionError("Couldn't find MTG leaf node with symbol \"Root\""))
    end
    
    root_len = get_roots_count(root_end[1])
    if root_len < m.root_max_len
        st = add_organ!(root_end[1], extra, "<", "Root", 2, index=1)
        status.carbon_root_creation_consumed = m.carbon_root_creation_cost
    end
end

##########################
### Decision model controlling the root growth model
##########################
PlantSimEngine.@process "root_growth_decision" verbose = false

struct ToyRootGrowthDecisionModel <: AbstractRoot_Growth_DecisionModel
    water_threshold::Float64
    carbon_root_creation_cost::Float64
end

PlantSimEngine.inputs_(::ToyRootGrowthDecisionModel) = 
(water_stock=0.0,carbon_stock=0.0)

PlantSimEngine.outputs_(::ToyRootGrowthDecisionModel) = NamedTuple()

PlantSimEngine.dep(::ToyRootGrowthDecisionModel) = (root_growth=AbstractRoot_GrowthModel=>["Root"],)

function PlantSimEngine.run!(m::ToyRootGrowthDecisionModel, models, status, meteo, constants=nothing, extra=nothing)

    if status.water_stock < m.water_threshold && status.carbon_stock > m.carbon_root_creation_cost
        status_Root= extra.statuses["Root"][1]
        PlantSimEngine.run!(extra.models["Root"].root_growth, models, status_Root, meteo, constants, extra)
    end
end


##########################
### Model accumulating carbon and water resources 
##########################

PlantSimEngine.@process "resource_stock_computation" verbose = false

struct ToyStockComputationModel <: AbstractResource_Stock_ComputationModel
end

PlantSimEngine.inputs_(::ToyStockComputationModel) = 
(water_absorbed=0.0,carbon_captured=0.0,carbon_organ_creation_consumed=0.0,carbon_root_creation_consumed=0.0)

PlantSimEngine.outputs_(::ToyStockComputationModel) = (water_stock=-Inf,carbon_stock=-Inf)

function PlantSimEngine.run!(m::ToyStockComputationModel, models, status, meteo, constants=nothing, extra=nothing)
    status.water_stock += sum(status.water_absorbed)
    status.carbon_stock += sum(status.carbon_captured) - sum(status.carbon_organ_creation_consumed) - sum(status.carbon_root_creation_consumed)
end


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


mapping = Dict(
"Scene" => ToyDegreeDaysCumulModel(),
"Plant" => (
    MultiScaleModel(
        model=ToyStockComputationModel(),          
        mapping=[
            :carbon_captured=>["Leaf"],
            :water_absorbed=>["Root"],
            PreviousTimeStep(:carbon_root_creation_consumed)=>"Root",
            PreviousTimeStep(:carbon_organ_creation_consumed)=>["Internode"],
        ],
        ),
        ToyRootGrowthDecisionModel(10.0, 50.0),
        Status(water_stock = 0.0, carbon_stock = 0.0)
    ),
"Internode" => (        
        MultiScaleModel(
            model=ToyCustomInternodeEmergence(),#TT_emergence=20.0),
            mapping=[:TT_cu => "Scene",
            :water_stock=>"Plant",
            :carbon_stock=>"Plant", 
            :carbon_root_creation_consumed=>"Root"],
        ),        
        Status(carbon_organ_creation_consumed=0.0),
    ),
"Root" =>   (ToyRootGrowthModel(50.0,10),       
            ToyWaterAbsorptionModel(),
            Status(carbon_root_creation_consumed=0.0, root_water_assimilation=1.0),
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

    plant_root_start = MultiScaleTreeGraph.Node(
        #MultiScaleTreeGraph.new_id(MultiScaleTreeGraph.get_root(plant)), 
        plant, 
        MultiScaleTreeGraph.NodeMTG("+", "Root", 1, 3), 
        #Dict{String, Any}("Root_len"=> 1)
    )
    #plant_root_start[:Root_len]=1

    meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)
    
    outs = run!(mtg, mapping, meteo_day)
    mtg


    length(MultiScaleTreeGraph.traverse(mtg,x->x, symbol="Leaf"))