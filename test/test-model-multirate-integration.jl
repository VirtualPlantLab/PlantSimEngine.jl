using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "hourly_leaf_flux" verbose = false
PlantSimEngine.@process "daily_plant_flux" verbose = false
PlantSimEngine.@process "daily_soil_state" verbose = false

struct HourlyLeafFluxModel <: AbstractHourly_Leaf_FluxModel end
struct DailyPlantFluxModel <: AbstractDaily_Plant_FluxModel end
struct DailySoilStateModel <: AbstractDaily_Soil_StateModel end
PlantSimEngine.inputs_(::HourlyLeafFluxModel) = (rate=0.0,)
PlantSimEngine.outputs_(::HourlyLeafFluxModel) = (flux=0.0, hourly_runs=0)
function PlantSimEngine.run!(::HourlyLeafFluxModel, status, environment, constants, context)
    status.flux = status.rate
    status.hourly_runs += 1
end
PlantSimEngine.inputs_(::DailyPlantFluxModel) = (leaf_fluxes=[0.0],)
PlantSimEngine.outputs_(::DailyPlantFluxModel) = (daily_total=0.0, daily_runs=0)
function PlantSimEngine.run!(::DailyPlantFluxModel, status, environment, constants, context)
    status.daily_total = sum(status.leaf_fluxes)
    status.daily_runs += 1
end
PlantSimEngine.inputs_(::DailySoilStateModel) = NamedTuple()
PlantSimEngine.outputs_(::DailySoilStateModel) = (soil_runs=0,)
function PlantSimEngine.run!(::DailySoilStateModel, status, environment, constants, context)
    status.soil_runs += 1
end

@testset "48-hour hourly/daily stack and plant isolation" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:soil; scale=:Soil, parent=:scene),
        Object(:plant_1; scale=:Plant, parent=:scene),
        Object(:plant_1_leaf_1; scale=:Leaf, parent=:plant_1, status=Status(rate=1.0)),
        Object(:plant_1_leaf_2; scale=:Leaf, parent=:plant_1, status=Status(rate=2.0)),
        Object(:plant_2; scale=:Plant, parent=:scene),
        Object(:plant_2_leaf_1; scale=:Leaf, parent=:plant_2, status=Status(rate=10.0)),
        Object(:plant_2_leaf_2; scale=:Leaf, parent=:plant_2, status=Status(rate=20.0));
        applications=(
            ModelSpec(HourlyLeafFluxModel(); name=:hourly_flux) |>
                AppliesTo(Many(scale=:Leaf)) |>
                TimeStep(Hour(1)),
            ModelSpec(DailyPlantFluxModel(); name=:daily_plant) |>
                AppliesTo(Many(scale=:Plant)) |>
                Inputs(:leaf_fluxes => Many(
                    scale=:Leaf,
                    within=Subtree(),
                    application=:hourly_flux,
                    var=:flux,
                    policy=Integrate(),
                    window=Day(1),
                )) |>
                TimeStep(Day(1)),
            ModelSpec(DailySoilStateModel(); name=:daily_soil) |>
                AppliesTo(One(scale=:Soil)) |>
                TimeStep(Day(1)),
        ),
        environment=[(duration=Hour(1),) for _ in 1:48],
    )
    compiled = Advanced.refresh_bindings!(model)
    schedule = Dict(row.application_id => row for row in explain_schedule(compiled))
    @test schedule[:hourly_flux].dt_seconds == 3600.0
    @test schedule[:daily_plant].dt_seconds == 86_400.0
    @test schedule[:daily_soil].dt_steps == 24.0

    simulation = run!(model; steps=23, outputs=:all)
    continue!(simulation; steps=25)
    @test current_step(simulation) == 48
    statuses = Dict(object.id.value => object.status for object in model_objects(model))
    @test all(statuses[id].hourly_runs == 48 for id in
              (:plant_1_leaf_1, :plant_1_leaf_2, :plant_2_leaf_1, :plant_2_leaf_2))
    @test statuses[:plant_1].daily_runs == 2
    @test statuses[:plant_2].daily_runs == 2
    @test statuses[:soil].soil_runs == 2
    @test statuses[:plant_1].daily_total == 72.0
    @test statuses[:plant_2].daily_total == 720.0

    plant_1_values = last.(outputs(simulation)[
        (:daily_plant, ObjectId(:plant_1), :daily_total)
    ])
    plant_2_values = last.(outputs(simulation)[
        (:daily_plant, ObjectId(:plant_2), :daily_total)
    ])
    @test plant_1_values == [3.0, 72.0]
    @test plant_2_values == [30.0, 720.0]
    @test all(isfinite, vcat(plant_1_values, plant_2_values))
end
