using Dates
using PlantMeteo
using PlantSimEngine
using Test

PlantSimEngine.@process "environment_sampling_probe" verbose = false
struct EnvironmentSamplingProbeModel <: AbstractEnvironment_Sampling_ProbeModel end
PlantSimEngine.inputs_(::EnvironmentSamplingProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::EnvironmentSamplingProbeModel) = (
    mean_T=0.0,
    min_T=0.0,
    max_T=0.0,
    mean_Rh=0.0,
    mean_radiation=0.0,
    radiation_energy=0.0,
)
PlantSimEngine.environment_inputs_(::EnvironmentSamplingProbeModel) = (
    T=0.0,
    Tmin=0.0,
    Tmax=0.0,
    Rh=0.0,
    Ri_SW_f=0.0,
    Ri_SW_q=0.0,
)
PlantSimEngine.environment_hint(::Type{<:EnvironmentSamplingProbeModel}) = (
    window=PlantMeteo.RollingWindow(2.0),
    bindings=(
        T=(source=:T, reducer=MeanWeighted()),
        Tmin=(source=:T, reducer=MinReducer()),
        Tmax=(source=:T, reducer=MaxReducer()),
        Rh=(source=:Rh, reducer=MeanWeighted()),
        Ri_SW_f=(source=:Ri_SW_f, reducer=MeanWeighted()),
        Ri_SW_q=(source=:Ri_SW_f, reducer=RadiationEnergy()),
    ),
)
function PlantSimEngine.run!(::EnvironmentSamplingProbeModel, status, environment, constants, context)
    status.mean_T = environment.T
    status.min_T = environment.Tmin
    status.max_T = environment.Tmax
    status.mean_Rh = environment.Rh
    status.mean_radiation = environment.Ri_SW_f
    status.radiation_energy = environment.Ri_SW_q
end

@testset "environment aggregation and model hint" begin
    if PlantSimEngine._has_environment_sampler_api()
        base_date = DateTime(2025, 1, 1)
        weather = Weather([
            Atmosphere(date=base_date, T=10.0, Wind=1.0, Rh=0.5, P=100.0, Ri_SW_f=100.0, duration=Hour(1)),
            Atmosphere(date=base_date + Hour(1), T=20.0, Wind=1.0, Rh=0.6, P=100.0, Ri_SW_f=200.0, duration=Hour(1)),
            Atmosphere(date=base_date + Hour(2), T=30.0, Wind=1.0, Rh=0.7, P=100.0, Ri_SW_f=300.0, duration=Hour(1)),
            Atmosphere(date=base_date + Hour(3), T=40.0, Wind=1.0, Rh=0.8, P=100.0, Ri_SW_f=400.0, duration=Hour(1)),
        ])
        model = CompositeModel(
            Object(:leaf; scale=:Leaf);
            applications=(
                ModelSpec(EnvironmentSamplingProbeModel(); name=:probe) |>
                    AppliesTo(One(scale=:Leaf)) |>
                    TimeStep(Hour(2)) |>
                    Environment(provider=:global),
            ),
            environment=weather,
        )
        bindings = only(explain_environment_bindings(Advanced.refresh_environment_bindings!(model)))
        @test bindings.temporal_sampler
        spec = Advanced.refresh_bindings!(model).applications_by_id[:probe].spec
        @test environment_bindings(spec).Ri_SW_q.reducer isa RadiationEnergy
        simulation = run!(model; steps=4, outputs=:all)
        values(variable) = getproperty.(
            collect_outputs(simulation, :leaf, variable; sink=nothing),
            :value,
        )
        @test values(:mean_T) == [10.0, 25.0]
        @test values(:min_T) == [10.0, 20.0]
        @test values(:max_T) == [10.0, 30.0]
        @test values(:mean_Rh) == [0.5, 0.65]
        @test values(:mean_radiation) == [100.0, 250.0]
        @test values(:radiation_energy) ≈ [0.36, 1.8]

        template = CompositeModelTemplate((
            ModelSpec(EnvironmentSamplingProbeModel(); name=:probe) |>
                AppliesTo(Many(scale=:Leaf)) |>
                TimeStep(Hour(2)) |>
                Environment(provider=:global),
        ))
        instance = ObjectInstance(
            :plant,
            template;
            root=Object(:plant_root; scale=:Plant),
            objects=(
                Object(:leaf_a; scale=:Leaf, parent=:plant_root),
                Object(:leaf_b; scale=:Leaf, parent=:plant_root),
            ),
            object_overrides=(
                Override(
                    object=:leaf_b,
                    application=:probe,
                    model=EnvironmentSamplingProbeModel(),
                ),
            ),
        )
        override_scene = CompositeModel(instance; environment=weather)
        override_compiled = Advanced.refresh_bindings!(override_scene)
        override_spec = override_compiled.applications_by_id[:plant__probe].spec
        @test environment_window(override_spec) isa PlantMeteo.RollingWindow
        @test environment_window(override_spec).dt == 2.0
        @test environment_bindings(override_spec).Ri_SW_q.reducer isa RadiationEnergy
        run!(override_scene; steps=4)
        for object in model_objects(override_scene; scale=:Leaf)
            @test object.status.mean_T == 25.0
            @test object.status.radiation_energy ≈ 1.8
        end
    else
        @test_skip "PlantMeteo weather sampler API unavailable"
    end
end
