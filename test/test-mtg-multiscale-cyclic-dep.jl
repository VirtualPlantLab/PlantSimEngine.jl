begin
    mtg = import_mtg_example()
    # Example meteo:
    meteo = Weather(
        [
        Atmosphere(T=20.0, Wind=1.0, Rh=0.65),
        Atmosphere(T=25.0, Wind=0.5, Rh=0.8)
    ]
    )

    out_vars = Dict(
        "Plant" => (:carbon_assimilation, :carbon_allocation, :aPPFD),
        "Leaf" => (:carbon_demand, :carbon_allocation, :carbon_biomass),
        "Internode" => (:carbon_demand, :carbon_allocation, :TT_cu_emergence, :carbon_biomass),
    )
end

@testset "Cyclic dependency" begin
    mapping_cyclic = Dict(
        "Plant" => (
            MultiScaleModel(
                model=ToyCAllocationModel(),
                mapping=[
                    :carbon_demand => ["Leaf", "Internode"],
                    :carbon_allocation => ["Leaf", "Internode"]
                ],
            ),
            MultiScaleModel(
                model=ToyPlantRmModel(),
                mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
            ),
            Status(total_surface=0.001, aPPFD=1300.0, soil_water_content=0.6),
        ),
        "Internode" => (
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
            Status(TT=10.0, carbon_biomass=1.0),
        ),
        "Leaf" => (
            ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
            ToyCBiomassModel(1.2),
            Status(TT=10.0),
        )
    )
    # In this mapping, we have a cyclic dependency with the carbon allocation and the carbon biomass. The carbon biomass depends on the carbon allocation, which itself depends on the
    # plant Rm, which depends on the Rm organs, which depends on the carbon biomass. This is a cyclic dependency that we need to break somewhere.

    @test_throws "Cyclic dependency detected in the graph. Cycle:" dep(mapping_cyclic)

    soft_dep_graphs_roots = PlantSimEngine.hard_dependencies(mapping_cyclic)
    dep_graph = PlantSimEngine.soft_dependencies_multiscale(soft_dep_graphs_roots, mapping_cyclic)
    iscyclic, cycle_vec = PlantSimEngine.is_graph_cyclic(dep_graph; warn=false)

    @test iscyclic
    @test cycle_vec == [ToyPlantRmModel() => "Plant", ToyMaintenanceRespirationModel{Float64}(2.1, 0.06, 25.0, 1.0, 0.025) => "Leaf", ToyCBiomassModel{Float64}(1.2) => "Leaf", ToyCAllocationModel() => "Plant", ToyPlantRmModel() => "Plant"]
end

# mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Plant", 1, 1))
# internode = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
# leaf = Node(mtg, MultiScaleTreeGraph.NodeMTG("<", "Leaf", 1, 2))

# mapping = Dict(
#     "Scene" => (
#         ToyDegreeDaysCumulModel(),
#         # MultiScaleModel(
#         #     model=ToyLAIfromLeafAreaModel(1.0),
#         #     mapping=[
#         #         PreviousTimeStep(:plant_surfaces) => "Plant" => :surface,
#         #         # We use PreviousTimeStep to break the cyclic dependency between the LAI and the leaf surface 
#         #         # that is computed as one of the latest sub-models.
#         #     ],
#         # ),
#         Beer(0.6),
#         # Status(plant_surfaces=0.001) # initialisation of the plant surfaces to break the cyclic dependency
#         Status(LAI=0.001)
#     ),
#     "Plant" => (
#         MultiScaleModel(
#             model=ToyPlantLeafSurfaceModel(),
#             mapping=[:leaf_surfaces => ["Leaf" => :surface],],
#         ),
#         MultiScaleModel(
#             model=ToyLightPartitioningModel(),
#             mapping=[
#                 :aPPFD_larger_scale => "Scene" => :aPPFD,
#                 # :total_surface => "Scene" #! put it again
#             ],
#         ),
#         MultiScaleModel(
#             model=ToyAssimModel(),
#             mapping=[
#                 :soil_water_content => "Soil",
#             ],
#         ),
#         MultiScaleModel(
#             model=ToyCAllocationModel(),
#             mapping=[
#                 :carbon_demand => ["Leaf", "Internode"],
#                 :carbon_allocation => ["Leaf", "Internode"]
#             ],
#         ),
#         MultiScaleModel(
#             model=ToyPlantRmModel(),
#             mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
#         ),
#         Status(total_surface=0.001), #! to remove
#     ),
#     "Internode" => (
#         MultiScaleModel(
#             model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
#             mapping=[:TT => "Scene",],
#         ),
#         MultiScaleModel(
#             model=ToyInternodeEmergence(TT_emergence=20.0),
#             mapping=[:TT_cu => "Scene"],
#         ),
#         ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
#         Status(carbon_biomass=1.0)
#     ),
#     "Leaf" => (
#         MultiScaleModel(
#             model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
#             mapping=[:TT => "Scene",],
#         ),
#         ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
#         ToyCBiomassModel(1.2),
#         ToyLeafSurfaceModel(0.1),
#         # Status(carbon_biomass=1.0)
#     ),
#     "Soil" => (
#         ToySoilWaterModel(),
#     ),
# )

# In this mapping, we have a cyclic dependency. The leaf surface is computed using the leaf biomass, which is computed using the carbon allocation, which itself depends on the 
# light interception, which is computed using the LAI at scene scale, itself coming from the plant total leaf surface, computed as the sum of all leaves surfaces. 
# This is a cyclic dependency that we need to break somewhere. We can break it by using the value of the leaf surface from the previous time-step, which is a common practice in
# plant models. This is done by flagging the leaf surface as a PreviousTimeStep variable in the mapping of the leaf node.

# out_vars = Dict(
#     "Scene" => (:TT_cu, :LAI),
#     "Plant" => (:carbon_assimilation, :carbon_allocation, :aPPFD),
#     "Leaf" => (:carbon_demand, :soil_water_content, :carbon_allocation, :carbon_biomass),
#     "Internode" => (:carbon_demand, :carbon_allocation, :TT_cu_emergence, :carbon_biomass),
#     "Soil" => (:soil_water_content,),
# )

#! update this:
# @testset "Mutiscale simulation -> cyclic dependency" begin
#     @test dep(mapping)

#     out = @test_nowarn run!(mtg, mapping, meteo, outputs=out_vars, executor=SequentialEx())

#     @test to_initialize(mapping) == Dict("Leaf" => [:var2]) # NB: :var1 is initialised in the status
#     @test to_initialize(mapping, simple_mtg) == Dict()
# end