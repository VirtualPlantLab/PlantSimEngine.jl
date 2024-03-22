mapping = Dict(
    "Plant" => (
        MultiScaleModel(
            model=ToyCAllocationModel(),
            mapping=[
                # inputs
                :carbon_assimilation => ["Leaf"],
                :carbon_demand => ["Leaf", "Internode"],
                # outputs
                :carbon_allocation => ["Leaf", "Internode"]
            ],
        ),
        MultiScaleModel(
            model=ToyPlantRmModel(),
            mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
        ),
    ),
    "Internode" => (
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
        Status(TT=10.0)
    ),
    "Leaf" => (
        MultiScaleModel(
            model=ToyAssimModel(),
            mapping=[:soil_water_content => "Soil",],
            # Notice we provide "Soil", not ["Soil"], so a single value is expected here
        ),
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
        ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
        Status(aPPFD=1300.0, TT=10.0),
    ),
    "Soil" => (
        ToySoilWaterModel(),
    ),
)

dep_graph = dep(mapping)

# The C allocation depends on the C demand at the leaf and internode levels,
# the maintenance respiration at the plant level, and the maintenance respiration at the plant level,
# which depends on the maintenance respiration at the leaf and internode levels.

# Expected root dependency nodes:
root_models = Dict(
    ("Soil" => :soil_water) => mapping["Soil"][1], # The only model from the soil is completely independent  
    ("Internode" => :carbon_demand) => mapping["Internode"][1], # The c allocation models dependent on TT, that is given as input:
    ("Leaf" => :carbon_demand) => mapping["Leaf"][2], # Same for the leaf
    ("Internode" => :maintenance_respiration) => mapping["Internode"][2], # The maintenance respiration model for the internode is independant
    ("Leaf" => :maintenance_respiration) => mapping["Leaf"][3], # The maintenance respiration model for the leaf is independant
)

for (proc, node) in dep_graph.roots # proc = ("Soil" => :soil_water) ; node = dep_graph.roots[proc]
    @test root_models[proc] == node.value
end

dump(dep_graph.roots["Internode"=>:carbon_demand])