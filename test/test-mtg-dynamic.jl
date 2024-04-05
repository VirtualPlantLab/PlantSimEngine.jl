# using PlantSimEngine, DataFrames, MultiScaleTreeGraph
# using PlantSimEngine.Examples;
mtg = import_mtg_example();

# Example meteo:
meteo = Weather(
    [
    Atmosphere(T=20.0, Wind=1.0, Rh=0.65),
    Atmosphere(T=25.0, Wind=0.5, Rh=0.8)
]
)

mapping = Dict(
    "Scene" => ToyDegreeDaysCumulModel(),
    "Plant" => (
        MultiScaleModel(
            model=ToyLAIModel(),
            mapping=[
                :TT_cu => "Scene",
            ],
        ),
        Beer(0.6),
        MultiScaleModel(
            model=ToyCAllocationModel(),
            mapping=[
                :carbon_assimilation => ["Leaf"],
                :carbon_demand => ["Leaf", "Internode"],
                :carbon_allocation => ["Leaf", "Internode"]
            ],
        ),
        MultiScaleModel(
            model=ToyPlantRmModel(),
            mapping=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
        ),
    ),
    "Internode" => (
        MultiScaleModel(
            model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            mapping=[:TT => "Scene",],
        ),
        MultiScaleModel(
            model=ToyInternodeEmergence(TT_emergence=20.0),
            mapping=[:TT_cu => "Scene"],
        ),
        ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
        Status(carbon_biomass=1.0)
    ),
    "Leaf" => (
        MultiScaleModel(
            model=ToyAssimModel(),
            mapping=[:soil_water_content => "Soil", :aPPFD => "Plant"],
        ),
        MultiScaleModel(
            model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            mapping=[:TT => "Scene",],
        ),
        ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025),
        Status(carbon_biomass=1.0)
    ),
    "Soil" => (
        ToySoilWaterModel(),
    ),
)

out_vars = Dict(
    "Leaf" => (:carbon_assimilation, :carbon_demand, :soil_water_content, :carbon_allocation),
    "Internode" => (:carbon_allocation, :TT_cu_emergence),
    "Plant" => (:carbon_allocation,),
    "Soil" => (:soil_water_content,),
)

out = run!(mtg, mapping, meteo, outputs=out_vars, executor=SequentialEx())

@testset "MTG with dynamic growth" begin
    st = out.statuses
    @test length(mtg) == 9
    @test length(st["Scene"]) == length(st["Soil"]) == length(st["Plant"]) == 1
    @test length(st["Internode"]) == length(st["Leaf"]) == 3
    @test st["Internode"][1].TT_cu_emergence == 0.0
    @test st["Internode"][end].TT_cu_emergence == 25.0

    out_df = outputs(out, DataFrame)
    @test unique(out_df[:, :organ]) |> sort == ["Internode", "Leaf", "Plant", "Soil"]
    @test filter(row -> row.organ == "Internode", out_df)[:, :TT_cu_emergence] == [0.0, 0.0, 0.0, 0.0, 25.0]
    @test filter(row -> row.organ == "Leaf", out_df)[:, :carbon_demand] == [0.5, 0.5, 0.75, 0.75, 0.75]
end