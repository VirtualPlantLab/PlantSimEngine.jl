using Dates

PlantSimEngine.@process "meteo_trait_consumer" verbose = false

struct MeteoTraitConsumerModel <: AbstractMeteo_Trait_ConsumerModel end

PlantSimEngine.inputs_(::MeteoTraitConsumerModel) = NamedTuple()
PlantSimEngine.outputs_(::MeteoTraitConsumerModel) = (meteo_seen=0.0,)
PlantSimEngine.meteo_inputs_(::MeteoTraitConsumerModel) = (T=0.0, CO2=400.0)

function PlantSimEngine.run!(::MeteoTraitConsumerModel, models, status, meteo, constants=nothing, extra=nothing)
    status.meteo_seen = meteo.T
    return nothing
end

@testset "Meteo traits" begin
    specs = Dict(:Leaf => Dict(:meteo_trait_consumer => ModelSpec(MeteoTraitConsumerModel())))

    @test_throws "CO2" PlantSimEngine.validate_meteo_inputs(
        specs,
        Atmosphere(T=20.0, Rh=0.65, Wind=1.0, duration=Dates.Hour(1))
    )

    @test PlantSimEngine.validate_meteo_inputs(
        specs,
        (T=20.0, CO2=410.0, duration=Dates.Hour(1))
    ) === nothing

    bound_spec = ModelSpec(
        MeteoTraitConsumerModel();
        meteo_bindings=(CO2=(source=:Ca, reducer=MeanReducer()),),
    )
    bound_specs = Dict(:Leaf => Dict(:meteo_trait_consumer => bound_spec))

    @test_throws "Ca" PlantSimEngine.validate_meteo_inputs(
        bound_specs,
        (T=20.0, CO2=410.0, duration=Dates.Hour(1))
    )
    @test PlantSimEngine.validate_meteo_inputs(
        bound_specs,
        (T=20.0, Ca=410.0, duration=Dates.Hour(1))
    ) === nothing

    model = CompositeModel(
        Object(:leaf; scale=:Leaf, status=Status(meteo_seen=0.0));
        applications=(
            ModelSpec(MeteoTraitConsumerModel()) |> AppliesTo(One(scale=:Leaf)),
        ),
        environment=(T=20.0, CO2=410.0, duration=Dates.Hour(1)),
    )
    @test validate_meteo_inputs(model) === nothing
end
