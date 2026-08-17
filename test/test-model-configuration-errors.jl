using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "invalid_hint_probe" verbose = false
PlantSimEngine.@process "configuration_probe" verbose = false
PlantSimEngine.@process "configuration_consumer" verbose = false
struct InvalidEnvironmentHintProbeModel <: AbstractInvalid_Hint_ProbeModel end
struct InvalidTimestepHintProbeModel <: AbstractInvalid_Hint_ProbeModel end
struct ConfigurationProbeModel <: AbstractConfiguration_ProbeModel end
struct ConfigurationConsumerModel <: AbstractConfiguration_ConsumerModel end
PlantSimEngine.inputs_(::Union{InvalidEnvironmentHintProbeModel,InvalidTimestepHintProbeModel}) = NamedTuple()
PlantSimEngine.outputs_(::Union{InvalidEnvironmentHintProbeModel,InvalidTimestepHintProbeModel}) = (value=0.0,)
PlantSimEngine.environment_hint(::Type{<:InvalidEnvironmentHintProbeModel}) = 42
PlantSimEngine.timestep_hint(::Type{<:InvalidTimestepHintProbeModel}) = "hourly"
PlantSimEngine.inputs_(::ConfigurationProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::ConfigurationProbeModel) = (value=0.0,)
PlantSimEngine.environment_inputs_(::ConfigurationProbeModel) = (T=0.0,)
PlantSimEngine.inputs_(::ConfigurationConsumerModel) = (value=Required(Float64),)
PlantSimEngine.outputs_(::ConfigurationConsumerModel) = (observed=0.0,)

function invalid_hint_scene(model)
    return CompositeModel(
        Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(model; name=:invalid_hint, on=One(scale=:Leaf)),
        ),
        environment=(duration=Hour(1),),
    )
end

@testset "current configuration errors" begin
    @test_throws "Unsupported reducer value" Aggregate(42)
    monthly_scene = CompositeModel(
        Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(InvalidTimestepHintProbeModel(); name=:monthly, on=One(scale=:Leaf), every=Month(1)),
        ),
        environment=(duration=Hour(1),),
    )
    @test_throws "Unsupported non-fixed period" Advanced.refresh_bindings!(monthly_scene)
    @test_throws "Invalid environment_hint" Advanced.refresh_bindings!(
        invalid_hint_scene(InvalidEnvironmentHintProbeModel())
    )
    @test_throws "Invalid timestep_hint" Advanced.refresh_bindings!(
        invalid_hint_scene(InvalidTimestepHintProbeModel())
    )
    invalid_environment = CompositeModel(
        Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(ConfigurationProbeModel(); name=:probe, on=One(scale=:Leaf), environment=Environment(provider=:global, sources=42)),
        ),
        environment=(T=20.0, duration=Hour(1)),
    )
    @test_throws Exception Advanced.refresh_bindings!(invalid_environment)

    invalid_policy = CompositeModel(
        Object(:source; scale=:Leaf, name=:source),
        Object(:consumer; scale=:Leaf, name=:consumer);
        applications=(
            ModelSpec(ConfigurationProbeModel(); name=:source, on=One(name=:source)),
            ModelSpec(ConfigurationConsumerModel(); name=:consumer, on=One(name=:consumer), inputs=(:value => One(
                    name=:source,
                    within=SceneScope(),
                    policy=:latest,
                ))),
        ),
        environment=(T=20.0, duration=Hour(1)),
    )
    @test_throws "Unsupported model input policy" Advanced.refresh_bindings!(invalid_policy)
end
