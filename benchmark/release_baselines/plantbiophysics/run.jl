using BenchmarkTools
using CSV
using DataFrames
using Dates
using PlantBiophysics
using PlantMeteo
using PlantSimEngine
using Random

const NSTEPS = parse(Int, get(ENV, "PSE_RELEASE_BASELINE_STEPS", "8760"))
const SAMPLES = parse(Int, get(ENV, "PSE_RELEASE_BASELINE_SAMPLES", "12"))

function forcing_set(n::Int)
    Random.seed!(1)
    ranges = (
        T=range(18, 40; length=10_000),
        Wind=range(0.5, 20; length=10_000),
        P=range(90, 101; length=10_000),
        Rh=range(0.1, 0.98; length=10_000),
        Ca=range(360, 900; length=10_000),
        JMaxRef=range(200.0, 300.0; length=10_000),
        VcMaxRef=range(150.0, 250.0; length=10_000),
        RdRef=range(0.3, 2.0; length=10_000),
        Ra_SW_f=range(10, 500; length=10_000),
        sky_fraction=range(0.0, 1.0; length=10_000),
        d=range(0.001, 0.5; length=10_000),
        TPURef=range(5.0, 20.0; length=10_000),
        g0=range(0.001, 2.0; length=10_000),
        g1=range(0.5, 15.0; length=10_000),
    )
    return DataFrame((; (
        name => [rand(values) for _ in 1:n]
        for (name, values) in pairs(ranges)
    )...))
end

function atmosphere(row)
    return Atmosphere(
        T=row.T,
        Wind=row.Wind,
        P=row.P,
        Rh=row.Rh,
        Cₐ=row.Ca,
        duration=Hour(1),
    )
end

function setup_workload(nsteps::Int)
    forcing = forcing_set(nsteps)
    first_row = first(eachrow(forcing))
    weather = Weather([atmosphere(row) for row in eachrow(forcing)])
    leaf = ModelMapping(
        energy_balance=Monteith(),
        photosynthesis=Fvcb(
            VcMaxRef=first_row.VcMaxRef,
            JMaxRef=first_row.JMaxRef,
            RdRef=first_row.RdRef,
            TPURef=first_row.TPURef,
        ),
        stomatal_conductance=Medlyn(first_row.g0, first_row.g1),
        status=(
            Ra_SW_f=first_row.Ra_SW_f,
            sky_fraction=first_row.sky_fraction,
            aPPFD=first_row.Ra_SW_f * 0.48 * 4.57,
            d=first_row.d,
        ),
    )
    return leaf, weather
end

warm_leaf, warm_weather = setup_workload(min(NSTEPS, 2))
run!(warm_leaf, warm_weather)

trial = @benchmark run!(leaf, weather) setup = (
    (leaf, weather) = setup_workload($NSTEPS)
) samples = SAMPLES evals = 1
estimate = BenchmarkTools.median(trial)
record = DataFrame([((;
    stack="PlantBiophysics v0.17.0 / PlantSimEngine v0.14.1",
    julia_version=string(VERSION),
    threads=Threads.nthreads(),
    nsteps=NSTEPS,
    samples=length(trial),
    output_policy="release default retained outputs",
    median_time_ns=estimate.time,
    median_time_per_step_ns=estimate.time / NSTEPS,
    median_memory_bytes=estimate.memory,
    median_allocations=estimate.allocs,
))])

output_path = isempty(ARGS) ? joinpath(@__DIR__, "latest.csv") : only(ARGS)
CSV.write(output_path, record)
record
