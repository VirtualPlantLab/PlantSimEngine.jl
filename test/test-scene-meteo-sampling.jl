using Dates
using PlantMeteo
using PlantSimEngine
using Test

PlantSimEngine.@process "meteo_sampling_probe" verbose = false
struct MeteoSamplingProbeModel <: AbstractMeteo_Sampling_ProbeModel end
PlantSimEngine.inputs_(::MeteoSamplingProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::MeteoSamplingProbeModel) = (
    mean_T=0.0,
    min_T=0.0,
    max_T=0.0,
    mean_Rh=0.0,
    mean_radiation=0.0,
    radiation_energy=0.0,
)
PlantSimEngine.meteo_inputs_(::MeteoSamplingProbeModel) = (
    T=0.0,
    Tmin=0.0,
    Tmax=0.0,
    Rh=0.0,
    Ri_SW_f=0.0,
    Ri_SW_q=0.0,
)
PlantSimEngine.meteo_hint(::Type{<:MeteoSamplingProbeModel}) = (
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
function PlantSimEngine.run!(::MeteoSamplingProbeModel, models, status, meteo, constants, extra)
    status.mean_T = meteo.T
    status.min_T = meteo.Tmin
    status.max_T = meteo.Tmax
    status.mean_Rh = meteo.Rh
    status.mean_radiation = meteo.Ri_SW_f
    status.radiation_energy = meteo.Ri_SW_q
end

@testset "meteorological aggregation and model hint" begin
    if PlantSimEngine._has_meteo_sampler_api()
        base_date = DateTime(2025, 1, 1)
        weather = Weather([
            Atmosphere(date=base_date, T=10.0, Wind=1.0, Rh=0.5, P=100.0, Ri_SW_f=100.0, duration=Hour(1)),
            Atmosphere(date=base_date + Hour(1), T=20.0, Wind=1.0, Rh=0.6, P=100.0, Ri_SW_f=200.0, duration=Hour(1)),
            Atmosphere(date=base_date + Hour(2), T=30.0, Wind=1.0, Rh=0.7, P=100.0, Ri_SW_f=300.0, duration=Hour(1)),
            Atmosphere(date=base_date + Hour(3), T=40.0, Wind=1.0, Rh=0.8, P=100.0, Ri_SW_f=400.0, duration=Hour(1)),
        ])
        scene = Scene(
            Object(:leaf; scale=:Leaf);
            applications=(
                ModelSpec(MeteoSamplingProbeModel(); name=:probe) |>
                    AppliesTo(One(scale=:Leaf)) |>
                    TimeStep(Hour(2)) |>
                    Environment(provider=:global),
            ),
            environment=weather,
        )
        bindings = only(explain_environment_bindings(Advanced.refresh_environment_bindings!(scene)))
        @test bindings.temporal_sampler
        spec = Advanced.refresh_bindings!(scene).applications_by_id[:probe].spec
        @test meteo_bindings(spec).Ri_SW_q.reducer isa RadiationEnergy
        simulation = run!(scene; steps=4, outputs=:all)
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
    else
        @test_skip "PlantMeteo weather sampler API unavailable"
    end
end
