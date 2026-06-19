using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "invalid_hint_probe" verbose = false
PlantSimEngine.@process "configuration_probe" verbose = false
PlantSimEngine.@process "configuration_consumer" verbose = false
struct InvalidMeteoHintProbeModel <: AbstractInvalid_Hint_ProbeModel end
struct InvalidTimestepHintProbeModel <: AbstractInvalid_Hint_ProbeModel end
struct ConfigurationProbeModel <: AbstractConfiguration_ProbeModel end
struct ConfigurationConsumerModel <: AbstractConfiguration_ConsumerModel end
PlantSimEngine.inputs_(::Union{InvalidMeteoHintProbeModel,InvalidTimestepHintProbeModel}) = NamedTuple()
PlantSimEngine.outputs_(::Union{InvalidMeteoHintProbeModel,InvalidTimestepHintProbeModel}) = (value=0.0,)
PlantSimEngine.meteo_hint(::Type{<:InvalidMeteoHintProbeModel}) = 42
PlantSimEngine.timestep_hint(::Type{<:InvalidTimestepHintProbeModel}) = "hourly"
PlantSimEngine.inputs_(::ConfigurationProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::ConfigurationProbeModel) = (value=0.0,)
PlantSimEngine.meteo_inputs_(::ConfigurationProbeModel) = (T=0.0,)
PlantSimEngine.inputs_(::ConfigurationConsumerModel) = (value=0.0,)
PlantSimEngine.outputs_(::ConfigurationConsumerModel) = (observed=0.0,)

function invalid_hint_scene(model)
    return Scene(
        Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(model; name=:invalid_hint) |> AppliesTo(One(scale=:Leaf)),
        ),
        environment=(duration=Hour(1),),
    )
end

@testset "current configuration errors" begin
    @test_throws "Unsupported reducer value" Aggregate(42)
    monthly_scene = Scene(
        Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(InvalidTimestepHintProbeModel(); name=:monthly) |>
                AppliesTo(One(scale=:Leaf)) |>
                TimeStep(Month(1)),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "Unsupported non-fixed period" Advanced.refresh_bindings!(monthly_scene)
    @test_throws "Invalid meteo_hint" Advanced.refresh_bindings!(
        invalid_hint_scene(InvalidMeteoHintProbeModel())
    )
    @test_throws "Invalid timestep_hint" Advanced.refresh_bindings!(
        invalid_hint_scene(InvalidTimestepHintProbeModel())
    )
    invalid_environment = Scene(
        Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(ConfigurationProbeModel(); name=:probe) |>
                AppliesTo(One(scale=:Leaf)) |>
                Environment(provider=:global, sources=42),
        ),
        environment=(T=20.0, duration=Hour(1)),
    )
    @test_throws Exception Advanced.refresh_bindings!(invalid_environment)

    invalid_policy = Scene(
        Object(:source; scale=:Leaf, name=:source),
        Object(:consumer; scale=:Leaf, name=:consumer);
        applications=(
            ModelSpec(ConfigurationProbeModel(); name=:source) |>
                AppliesTo(One(name=:source)),
            ModelSpec(ConfigurationConsumerModel(); name=:consumer) |>
                AppliesTo(One(name=:consumer)) |>
                Inputs(:value => One(
                    name=:source,
                    within=SceneScope(),
                    policy=:latest,
                )),
        ),
        environment=(T=20.0, duration=Hour(1)),
    )
    @test_throws "Unsupported scene input policy" Advanced.refresh_bindings!(invalid_policy)
end
