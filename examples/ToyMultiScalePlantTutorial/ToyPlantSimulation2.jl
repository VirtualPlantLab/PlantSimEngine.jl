###########################################
# Toy plant model 
# Physiologically and physically completely meaningless 
# (no dimension for units, arbitrary values, stores water and carbon in abstract stocks,
#  arbitrary max leaf count and root length, constant and non-coupled photosynthesis and water absorption, ...)
# But it should illustrate the basics of simulating a growing multiscale plant with PlantSimEngine's model approach
###########################################

function get_root_end_node(node::MultiScaleTreeGraph.Node)
    root = MultiScaleTreeGraph.get_root(node)
    return MultiScaleTreeGraph.traverse(root, x -> x, symbol="Root", filter_fun=MultiScaleTreeGraph.isleaf)
end

function get_roots_count(node::MultiScaleTreeGraph.Node)
    root = MultiScaleTreeGraph.get_root(node)
    return length(MultiScaleTreeGraph.traverse(root, x -> x, symbol="Root"))
end

function get_n_leaves(node::MultiScaleTreeGraph.Node)
    root = MultiScaleTreeGraph.get_root(node)
    nleaves = length(MultiScaleTreeGraph.traverse(root, x -> 1, symbol="Leaf"))
    return nleaves
end

PlantSimEngine.@process "organ_emergence" verbose = false

struct ToyCustomInternodeEmergence{T} <: AbstractOrgan_EmergenceModel
    TT_emergence::T
    carbon_internode_creation_cost::T
    leaf_surface_area::T
    leaves_max_surface_area::T
    water_leaf_threshold::T
end

ToyCustomInternodeEmergence(; TT_emergence=300.0, carbon_internode_creation_cost=200.0, leaf_surface_area=3.0, leaves_max_surface_area=100.0,
    water_leaf_threshold=30.0) = ToyCustomInternodeEmergence(TT_emergence, carbon_internode_creation_cost, leaf_surface_area, leaves_max_surface_area, water_leaf_threshold)

PlantSimEngine.inputs_(m::ToyCustomInternodeEmergence) = (TT_cu=0.0, water_stock=0.0, carbon_stock=0.0)
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

struct ToyRootGrowthModel{T} <: AbstractRoot_GrowthModel
    water_threshold::T
    carbon_root_creation_cost::T
    root_max_len::Int
end

PlantSimEngine.inputs_(::ToyRootGrowthModel) = (water_stock=0.0, carbon_stock=0.0,)
PlantSimEngine.outputs_(::ToyRootGrowthModel) = (carbon_root_creation_consumed=0.0,)

function PlantSimEngine.run!(m::ToyRootGrowthModel, models, status, meteo, constants=nothing, extra=nothing)
    if status.water_stock < m.water_threshold && status.carbon_stock > m.carbon_root_creation_cost

        root_end = get_root_end_node(status.node)

        if length(root_end) != 1
            throw(AssertionError("Couldn't find MTG leaf node with symbol \"Root\""))
        end
        root_len = get_roots_count(root_end[1])
        if root_len < m.root_max_len
            st = add_organ!(root_end[1], extra, "<", "Root", 2, index=1)
            status.carbon_root_creation_consumed = m.carbon_root_creation_cost
        end
    else
        status.carbon_root_creation_consumed = 0.0
    end
end

##########################
### Model accumulating carbon and water resources 
##########################

PlantSimEngine.@process "resource_stock_computation" verbose = false

struct ToyStockComputationModel <: AbstractResource_Stock_ComputationModel
end
#status.water_stock += meteo.precipitations * root_water_assimilation_ratio

PlantSimEngine.inputs_(::ToyStockComputationModel) =
    (water_absorbed=0.0, carbon_captured=0.0, carbon_organ_creation_consumed=0.0, carbon_root_creation_consumed=0.0)

PlantSimEngine.outputs_(::ToyStockComputationModel) = (water_stock=-Inf, carbon_stock=-Inf)

function PlantSimEngine.run!(m::ToyStockComputationModel, models, status, meteo, constants=nothing, extra=nothing)
    status.water_stock += sum(status.water_absorbed) #- status.water_transpiration
    status.carbon_stock += sum(status.carbon_captured) - sum(status.carbon_organ_creation_consumed) - sum(status.carbon_root_creation_consumed)

    if status.water_stock < 0.0
        status.water_stock = 0.0
    end
end

PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyStockComputationModel}) = PlantSimEngine.IsTimeStepIndependent()
PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyStockComputationModel}) = PlantSimEngine.IsObjectIndependent()

########################
## Leaf model capturing some arbitrary carbon quantity
########################

PlantSimEngine.@process "leaf_carbon_capture" verbose = false

struct ToyLeafCarbonCaptureModel <: AbstractLeaf_Carbon_CaptureModel end

function PlantSimEngine.inputs_(::ToyLeafCarbonCaptureModel)
    NamedTuple()#(TT_cu=-Inf)
end

function PlantSimEngine.outputs_(::ToyLeafCarbonCaptureModel)
    (carbon_captured=0.0,)
end

function PlantSimEngine.run!(::ToyLeafCarbonCaptureModel, models, status, meteo, constants, extra)
    # very crude approximation with LAI of 1 and constant aPPFD
    status.carbon_captured = 200.0 * (1.0 - exp(-0.2))
end

PlantSimEngine.ObjectDependencyTrait(::Type{<:ToyLeafCarbonCaptureModel}) = PlantSimEngine.IsObjectIndependent()
PlantSimEngine.TimeStepDependencyTrait(::Type{<:ToyLeafCarbonCaptureModel}) = PlantSimEngine.IsTimeStepIndependent()

mapping = Dict(
    "Scene" => ToyDegreeDaysCumulModel(),
    "Plant" => (
        MultiScaleModel(
            model=ToyStockComputationModel(),
            mapped_variables=[
                :carbon_captured => ["Leaf"],
                :water_absorbed => ["Root"],
                :carbon_root_creation_consumed => ["Root"],
                :carbon_organ_creation_consumed => ["Internode"]],
        ),
        Status(water_stock=0.0, carbon_stock=0.0)
    ),
    "Internode" => (
        MultiScaleModel(
            model=ToyCustomInternodeEmergence(),#TT_emergence=20.0),
            mapped_variables=[:TT_cu => "Scene",
                PreviousTimeStep(:water_stock) => "Plant",
                PreviousTimeStep(:carbon_stock) => "Plant"],
        ),
        Status(carbon_organ_creation_consumed=0.0),
    ),
    "Root" => (MultiScaleModel(
            model=ToyRootGrowthModel(10.0, 50.0, 10),
            mapped_variables=[PreviousTimeStep(:carbon_stock) => "Plant",
                PreviousTimeStep(:water_stock) => "Plant"],
        ),
        ToyWaterAbsorptionModel(),
        Status(carbon_root_creation_consumed=0.0, root_water_assimilation=1.0),
    ),
    "Leaf" => (ToyLeafCarbonCaptureModel(),),
)

mtg = MultiScaleTreeGraph.Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0))

plant = MultiScaleTreeGraph.Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))

internode1 = MultiScaleTreeGraph.Node(plant, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
MultiScaleTreeGraph.Node(internode1, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
MultiScaleTreeGraph.Node(internode1, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))

internode2 = MultiScaleTreeGraph.Node(internode1, MultiScaleTreeGraph.NodeMTG("<", "Internode", 1, 2))
MultiScaleTreeGraph.Node(internode2, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
MultiScaleTreeGraph.Node(internode2, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))

plant_root_start = MultiScaleTreeGraph.Node(
    plant,
    MultiScaleTreeGraph.NodeMTG("+", "Root", 1, 3),
)

meteo_day = CSV.read(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), DataFrame, header=18)

outs = run!(mtg, mapping, meteo_day)
mtg


length(MultiScaleTreeGraph.traverse(mtg, x -> x, symbol="Leaf"))