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

mapping = ModelMapping(
    "Scene" => ToyDegreeDaysCumulModel(),
    "Plant" => (
        MultiScaleModel(
            model=ToyLAIModel(),
            mapped_variables=[
                :TT_cu => "Scene",
            ],
        ),
        Beer(0.6),
        MultiScaleModel(
            model=ToyCAllocationModel(),
            mapped_variables=[
                :carbon_assimilation => ["Leaf"],
                :carbon_demand => ["Leaf", "Internode"],
                :carbon_allocation => ["Leaf", "Internode"]
            ],
        ),
        MultiScaleModel(
            model=ToyPlantRmModel(),
            mapped_variables=[:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm],],
        ),
    ),
    "Internode" => (
        MultiScaleModel(
            model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            mapped_variables=[:TT => "Scene",],
        ),
        MultiScaleModel(
            model=ToyInternodeEmergence(TT_emergence=20.0),
            mapped_variables=[:TT_cu => "Scene"],
        ),
        ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004),
        Status(carbon_biomass=1.0)
    ),
    "Leaf" => (
        MultiScaleModel(
            model=ToyAssimModel(),
            mapped_variables=[:soil_water_content => "Soil", :aPPFD => "Plant"],
        ),
        MultiScaleModel(
            model=ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0),
            mapped_variables=[:TT => "Scene",],
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

nsteps = PlantSimEngine.get_nsteps(meteo)
sim = PlantSimEngine.GraphSimulation(mtg, mapping, nsteps=nsteps, check=true, outputs=out_vars)
out = run!(sim,meteo)
#out = run!(mtg, mapping, meteo, tracked_outputs=out_vars, executor=SequentialEx())

@testset "MTG with dynamic growth" begin
    st = sim.statuses
    @test length(mtg) == 9
    @test length(st["Scene"]) == length(st["Soil"]) == length(st["Plant"]) == 1
    @test length(st["Internode"]) == length(st["Leaf"]) == 3
    @test st["Internode"][1].TT_cu_emergence == 0.0
    @test st["Internode"][end].TT_cu_emergence == 25.0

    out_df_dict = convert_outputs(out, DataFrame)
    @test collect(keys(out_df_dict)) |> sort == ["Internode", "Leaf", "Plant", "Soil"]
    @test out_df_dict["Internode"][:, :TT_cu_emergence] == [0.0, 0.0, 0.0, 0.0, 25.0]
    @test out_df_dict["Leaf"][:, :carbon_demand] == [0.5, 0.5, 0.75, 0.75, 0.75]
end

@testset "MTG with mixed daily/hourly clocks (2 leaves)" begin
    mtg2 = Node(MultiScaleTreeGraph.NodeMTG("/", "Scene", 1, 0))
    plant2 = Node(mtg2, MultiScaleTreeGraph.NodeMTG("+", "Plant", 1, 1))
    Node(mtg2, MultiScaleTreeGraph.NodeMTG("+", "Soil", 1, 1))
    internode2 = Node(plant2, MultiScaleTreeGraph.NodeMTG("/", "Internode", 1, 2))
    Node(internode2, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))
    Node(internode2, MultiScaleTreeGraph.NodeMTG("+", "Leaf", 1, 2))

    daily = ClockSpec(24.0, 1.0)
    hourly = 1.0

    mapping2 = Dict(
        "Scene" => (
            ModelSpec(ToyDegreeDaysCumulModel()) |> TimeStepModel(daily),
        ),
        "Plant" => (
            ModelSpec(ToyLAIModel()) |>
            MultiScaleModel([:TT_cu => "Scene"]) |>
            TimeStepModel(daily),
            ModelSpec(Beer(0.6)) |> TimeStepModel(hourly),
            ModelSpec(ToyCAllocationModel()) |>
            MultiScaleModel([
                :carbon_assimilation => ["Leaf"],
                :carbon_demand => ["Leaf", "Internode"],
                :carbon_allocation => ["Leaf", "Internode"],
            ]) |>
            InputBindings(; carbon_assimilation=(process=process(ToyAssimModel()), var=:carbon_assimilation, scale="Leaf", policy=Integrate())) |>
            TimeStepModel(daily),
            ModelSpec(ToyPlantRmModel()) |>
            MultiScaleModel([:Rm_organs => ["Leaf" => :Rm, "Internode" => :Rm]]) |>
            TimeStepModel(daily),
        ),
        "Internode" => (
            ModelSpec(ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0)) |>
            MultiScaleModel([:TT => "Scene"]) |>
            TimeStepModel(daily),
            # Keep emergence model in the stack (as in the dynamic test), but prevent growth in this scenario.
            ModelSpec(ToyInternodeEmergence(TT_emergence=1.0e6)) |>
            MultiScaleModel([:TT_cu => "Scene"]) |>
            TimeStepModel(daily),
            ModelSpec(ToyMaintenanceRespirationModel(1.5, 0.06, 25.0, 0.6, 0.004)) |> TimeStepModel(daily),
            Status(carbon_biomass=1.0),
        ),
        "Leaf" => (
            ModelSpec(ToyAssimModel()) |>
            MultiScaleModel([:soil_water_content => "Soil", :aPPFD => "Plant"]) |>
            TimeStepModel(hourly),
            ModelSpec(ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0)) |>
            MultiScaleModel([:TT => "Scene"]) |>
            TimeStepModel(daily),
            ModelSpec(ToyMaintenanceRespirationModel(2.1, 0.06, 25.0, 1.0, 0.025)) |> TimeStepModel(daily),
            Status(carbon_biomass=1.0),
        ),
        "Soil" => (
            ModelSpec(ToySoilWaterModel()) |> TimeStepModel(daily),
        ),
    )

    out_vars2 = Dict(
        "Leaf" => (:carbon_assimilation, :aPPFD, :carbon_demand),
        "Plant" => (:LAI, :carbon_offer, :Rm),
        "Scene" => (:TT, :TT_cu),
        "Soil" => (:soil_water_content,),
        "Internode" => (:carbon_demand, :TT_cu_emergence),
    )

    nsteps2 = 48
    meteo2 = Weather(repeat([Atmosphere(T=20.0, Wind=1.0, Rh=0.65, Ri_PAR_f=300.0)], nsteps2))
    sim2 = PlantSimEngine.GraphSimulation(mtg2, mapping2, nsteps=nsteps2, check=true, outputs=out_vars2)
    out2 = run!(sim2, meteo2, executor=SequentialEx())

    st2 = status(sim2)
    @test length(st2["Scene"]) == length(st2["Soil"]) == length(st2["Plant"]) == length(st2["Internode"]) == 1
    @test length(st2["Leaf"]) == 2

    scope = ScopeId(:global, 1)
    last_run = sim2.temporal_state.last_run
    p_dd = process(ToyDegreeDaysCumulModel())
    p_lai = process(ToyLAIModel())
    p_beer = process(Beer(0.6))
    p_assim = process(ToyAssimModel())
    p_alloc = process(ToyCAllocationModel())
    p_cdemand = process(ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0))
    p_soil = process(ToySoilWaterModel())

    @test last_run[ModelKey(scope, "Plant", p_beer)] == 48.0
    @test last_run[ModelKey(scope, "Leaf", p_assim)] == 48.0

    @test last_run[ModelKey(scope, "Scene", p_dd)] == 25.0
    @test last_run[ModelKey(scope, "Plant", p_lai)] == 25.0
    @test last_run[ModelKey(scope, "Plant", p_alloc)] == 25.0
    @test last_run[ModelKey(scope, "Leaf", p_cdemand)] == 25.0
    @test last_run[ModelKey(scope, "Soil", p_soil)] == 25.0

    @test st2["Scene"][1].TT_cu == 20.0
    last_daily_run = last_run[ModelKey(scope, "Plant", p_alloc)]
    window_start = last_daily_run - daily.dt + 1.0
    out2_df = convert_outputs(out2, DataFrame)
    integrated_assim_window = sum(
        row.carbon_assimilation for row in eachrow(out2_df["Leaf"])
        if row.timestep >= window_start - 1e-8 && row.timestep <= last_daily_run + 1e-8
    )
    @test integrated_assim_window > 0.0
    @test isfinite(st2["Plant"][1].carbon_offer)
    @test st2["Plant"][1].carbon_offer > -st2["Plant"][1].Rm
    @test !isempty(out2["Leaf"])
end
