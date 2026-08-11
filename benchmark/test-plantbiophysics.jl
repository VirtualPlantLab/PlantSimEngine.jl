using BenchmarkTools
using CSV
using Dates
using DataFrames
using PlantBiophysics
using PlantMeteo
using PlantSimEngine
using Random

function _plantbiophysics_forcing_set(n::Int)
    Random.seed!(1)
    length_range = 10_000
    ranges = (
        T=range(18, 40; length=length_range),
        Wind=range(0.5, 20; length=length_range),
        P=range(90, 101; length=length_range),
        Rh=range(0.1, 0.98; length=length_range),
        Ca=range(360, 900; length=length_range),
        JMaxRef=range(200.0, 300.0; length=length_range),
        VcMaxRef=range(150.0, 250.0; length=length_range),
        RdRef=range(0.3, 2.0; length=length_range),
        Ra_SW_f=range(10, 500; length=length_range),
        sky_fraction=range(0.0, 1.0; length=length_range),
        d=range(0.001, 0.5; length=length_range),
        TPURef=range(5.0, 20.0; length=length_range),
        g0=range(0.001, 2.0; length=length_range),
        g1=range(0.5, 15.0; length=length_range),
    )
    columns = (; (
        name => [rand(values) for _ in 1:n]
        for (name, values) in pairs(ranges)
    )...)
    return DataFrame(columns)
end

function _plantbiophysics_atmosphere(row)
    return Atmosphere(
        T=row.T,
        Wind=row.Wind,
        P=row.P,
        Rh=row.Rh,
        Cₐ=row.Ca,
        duration=Hour(1),
    )
end

function _plantbiophysics_leaf_scene(
    row;
    environment=_plantbiophysics_atmosphere(row),
)
    return PlantBiophysics.leaf_scene(
        Monteith(),
        Fvcb(
            VcMaxRef=row.VcMaxRef,
            JMaxRef=row.JMaxRef,
            RdRef=row.RdRef,
            TPURef=row.TPURef,
        ),
        Medlyn(row.g0, row.g1);
        status=Status(
            Ra_SW_f=row.Ra_SW_f,
            sky_fraction=row.sky_fraction,
            aPPFD=row.Ra_SW_f * 0.48 * 4.57,
            d=row.d,
        ),
        environment=environment,
    )
end

function setup_plantbiophysics_multistep(; nsteps=8760)
    forcing = _plantbiophysics_forcing_set(nsteps)
    environment = Weather([
        _plantbiophysics_atmosphere(row)
        for row in eachrow(forcing)
    ])
    return (
        _plantbiophysics_leaf_scene(first(eachrow(forcing)); environment),
        nsteps,
    )
end

function benchmark_plantbiophysics_multistep(model, nsteps; outputs=:none)
    return run!(model; steps=nsteps, outputs=outputs)
end

function setup_benchmark_plantbiophysics_batch(; n=100)
    forcing = _plantbiophysics_forcing_set(n)
    return [_plantbiophysics_leaf_scene(row) for row in eachrow(forcing)]
end

function benchmark_plantbiophysics_batch(scenes)
    constants = Constants()
    for model in scenes
        run!(model; constants=constants, outputs=:none)
    end
    return nothing
end

function benchmark_plantbiophysics_fanout(; n=100)
    scenes = setup_benchmark_plantbiophysics_batch(; n=n)
    return benchmark_plantbiophysics_batch(scenes)
end

function _plantbiophysics_performance_record(
    stage,
    trial;
    scope,
    output_policy,
    nscenes,
    nsteps_per_scene,
)
    median_estimate = BenchmarkTools.median(trial)
    minimum_estimate = BenchmarkTools.minimum(trial)
    total_model_steps = nscenes * nsteps_per_scene
    median_time_per_step_ns = if iszero(total_model_steps)
        NaN
    else
        median_estimate.time / total_model_steps
    end
    minimum_time_per_step_ns = if iszero(total_model_steps)
        NaN
    else
        minimum_estimate.time / total_model_steps
    end
    return (
        recorded_at=Dates.format(
            Dates.now(),
            dateformat"yyyy-mm-ddTHH:MM:SS.sss",
        ),
        stage=String(stage),
        julia_version=string(VERSION),
        threads=Threads.nthreads(),
        plantsimengine_version=string(pkgversion(PlantSimEngine)),
        plantbiophysics_version=string(pkgversion(PlantBiophysics)),
        scope=String(scope),
        output_policy=String(output_policy),
        nscenes=nscenes,
        nsteps_per_scene=nsteps_per_scene,
        total_model_steps=total_model_steps,
        samples=length(trial),
        median_time_ns=median_estimate.time,
        minimum_time_ns=minimum_estimate.time,
        median_time_per_step_ns=median_time_per_step_ns,
        minimum_time_per_step_ns=minimum_time_per_step_ns,
        median_memory_bytes=median_estimate.memory,
        minimum_memory_bytes=minimum_estimate.memory,
        median_allocations=median_estimate.allocs,
        minimum_allocations=minimum_estimate.allocs,
    )
end

function run_plantbiophysics_performance_profile(;
    nsteps=8760,
    fanout_scenes=100,
    samples=10,
)
    nsteps > 0 || error("PlantBiophysics benchmark step count must be positive.")
    fanout_scenes > 0 ||
        error("PlantBiophysics benchmark fan-out count must be positive.")
    samples > 0 ||
        error("PlantBiophysics benchmark sample count must be positive.")

    warm_model, warm_steps = setup_plantbiophysics_multistep(;
        nsteps=min(nsteps, 2),
    )
    benchmark_plantbiophysics_multistep(
        warm_model,
        warm_steps;
        outputs=:none,
    )
    warm_model, warm_steps = setup_plantbiophysics_multistep(;
        nsteps=min(nsteps, 2),
    )
    benchmark_plantbiophysics_multistep(
        warm_model,
        warm_steps;
        outputs=:all,
    )
    benchmark_plantbiophysics_fanout(; n=min(fanout_scenes, 2))

    no_retention_trial = BenchmarkTools.@benchmark benchmark_plantbiophysics_multistep(
        model,
        $nsteps;
        outputs=:none,
    ) setup = ((model, setup_steps) = setup_plantbiophysics_multistep(
        nsteps=$nsteps,
    )) samples = samples evals = 1
    retain_all_trial = BenchmarkTools.@benchmark benchmark_plantbiophysics_multistep(
        model,
        $nsteps;
        outputs=:all,
    ) setup = ((model, setup_steps) = setup_plantbiophysics_multistep(
        nsteps=$nsteps,
    )) samples = samples evals = 1
    construction_trial = BenchmarkTools.@benchmark setup_plantbiophysics_multistep(
        nsteps=$nsteps,
    ) samples = samples evals = 1
    fanout_trial = BenchmarkTools.@benchmark benchmark_plantbiophysics_batch(
        scenes,
    ) setup = (scenes = setup_benchmark_plantbiophysics_batch(
        n=$fanout_scenes,
    )) samples = samples evals = 1

    return [
        _plantbiophysics_performance_record(
            :steady_state_no_retention,
            no_retention_trial;
            scope=:one_setup_many_timesteps,
            output_policy=:none,
            nscenes=1,
            nsteps_per_scene=nsteps,
        ),
        _plantbiophysics_performance_record(
            :steady_state_retain_all,
            retain_all_trial;
            scope=:one_setup_many_timesteps,
            output_policy=:all,
            nscenes=1,
            nsteps_per_scene=nsteps,
        ),
        _plantbiophysics_performance_record(
            :construction_only,
            construction_trial;
            scope=:setup,
            output_policy=:not_applicable,
            nscenes=1,
            nsteps_per_scene=0,
        ),
        _plantbiophysics_performance_record(
            :one_step_fanout,
            fanout_trial;
            scope=:many_setups_one_timestep,
            output_policy=:none,
            nscenes=fanout_scenes,
            nsteps_per_scene=1,
        ),
    ]
end

function write_plantbiophysics_performance_profile(
    path;
    nsteps=8760,
    fanout_scenes=100,
    samples=10,
)
    records = run_plantbiophysics_performance_profile(;
        nsteps=nsteps,
        fanout_scenes=fanout_scenes,
        samples=samples,
    )
    mkpath(dirname(path))
    CSV.write(path, DataFrame(records))
    return records
end
