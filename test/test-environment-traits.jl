using Dates

PlantSimEngine.@process "environment_trait_consumer" verbose = false

struct EnvironmentTraitConsumerModel <: AbstractEnvironment_Trait_ConsumerModel end

PlantSimEngine.inputs_(::EnvironmentTraitConsumerModel) = NamedTuple()
PlantSimEngine.outputs_(::EnvironmentTraitConsumerModel) = (environment_seen=0.0,)
PlantSimEngine.environment_inputs_(::EnvironmentTraitConsumerModel) = (T=0.0, CO2=400.0)

function PlantSimEngine.run!(::EnvironmentTraitConsumerModel, status, environment, constants=nothing, context=nothing)
    status.environment_seen = environment.T
    return nothing
end

@testset "Environment traits" begin
    specs = Dict(:Leaf => Dict(:environment_trait_consumer => ModelSpec(EnvironmentTraitConsumerModel())))

    @test_throws "CO2" PlantSimEngine.validate_environment_inputs(
        specs,
        Atmosphere(T=20.0, Rh=0.65, Wind=1.0, duration=Dates.Hour(1))
    )

    @test PlantSimEngine.validate_environment_inputs(
        specs,
        (T=20.0, CO2=410.0, duration=Dates.Hour(1))
    ) === nothing

    bound_spec = ModelSpec(
        EnvironmentTraitConsumerModel();
        environment_bindings=(CO2=(source=:Ca, reducer=MeanReducer()),),
    )
    bound_specs = Dict(:Leaf => Dict(:environment_trait_consumer => bound_spec))

    @test_throws "Ca" PlantSimEngine.validate_environment_inputs(
        bound_specs,
        (T=20.0, CO2=410.0, duration=Dates.Hour(1))
    )
    @test PlantSimEngine.validate_environment_inputs(
        bound_specs,
        (T=20.0, Ca=410.0, duration=Dates.Hour(1))
    ) === nothing

    model = CompositeModel(
        Object(:leaf; scale=:Leaf, status=Status(environment_seen=0.0));
        applications=(
            ModelSpec(EnvironmentTraitConsumerModel()) |> AppliesTo(One(scale=:Leaf)),
        ),
        environment=(T=20.0, CO2=410.0, duration=Dates.Hour(1)),
    )
    @test validate_environment_inputs(model) === nothing
end
