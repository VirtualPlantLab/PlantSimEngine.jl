using BenchmarkTools
using CSV
using DataFrames
using XPalm

const SAMPLES = parse(Int, get(ENV, "PSE_RELEASE_BASELINE_SAMPLES", "5"))
const REFERENCE_VARIABLES = Dict{Symbol,Any}(
    :Scene => (:lai, :leaf_area, :aPPFD),
    :Plant => (
        :plant_age,
        :leaf_area,
        :aPPFD,
        :Rm,
        :carbon_assimilation,
        :phytomer_count,
        :biomass_bunch_harvested,
        :biomass_bunch_harvested_cum,
        :n_bunches_harvested,
        :n_bunches_harvested_cum,
        :biomass_oil_harvested,
        :biomass_oil_harvested_cum,
    ),
    :Soil => (:ftsw, :root_depth),
)

function setup_workload()
    meteo = CSV.read(
        joinpath(dirname(dirname(pathof(XPalm))), "0-data", "meteo.csv"),
        DataFrame,
    )
    palm = XPalm.Palm(
        initiation_age=0,
        parameters=XPalm.default_parameters(),
    )
    return meteo, palm
end

function run_workload(meteo, palm)
    return XPalm.xpalm(
        meteo,
        DataFrame;
        vars=REFERENCE_VARIABLES,
        architecture=false,
        palm=palm,
    )
end

warm_meteo, warm_palm = setup_workload()
run_workload(warm_meteo[1:100, :], warm_palm)

trial = @benchmark run_workload(meteo, palm) setup = (
    (meteo, palm) = setup_workload()
) samples = SAMPLES evals = 1
estimate = BenchmarkTools.median(trial)

check_meteo, check_palm = setup_workload()
outputs = run_workload(check_meteo, check_palm)
final_state = (
    current_step=nrow(outputs[:Plant]),
    phytomer_count=last(outputs[:Plant].phytomer_count),
    lai=last(outputs[:Scene].lai),
    ftsw=last(outputs[:Soil].ftsw),
)
expected = (
    current_step=4160,
    phytomer_count=344,
    lai=5.0587602356164405,
    ftsw=0.7991179101191216,
)
final_state.current_step == expected.current_step || error("XPalm step mismatch")
final_state.phytomer_count == expected.phytomer_count || error("XPalm phytomer mismatch")
isapprox(final_state.lai, expected.lai; atol=1.0e-8, rtol=1.0e-8) ||
    error("XPalm LAI mismatch")
isapprox(final_state.ftsw, expected.ftsw; atol=1.0e-8, rtol=1.0e-8) ||
    error("XPalm FTSW mismatch")

record = DataFrame([((;
    stack="XPalm v0.6.1 / PlantSimEngine v0.14.1",
    julia_version=string(VERSION),
    threads=Threads.nthreads(),
    nsteps=final_state.current_step,
    samples=length(trial),
    output_policy="historical requested outputs and DataFrame materialization",
    median_time_ns=estimate.time,
    median_time_per_step_ns=estimate.time / final_state.current_step,
    median_memory_bytes=estimate.memory,
    median_allocations=estimate.allocs,
    phytomer_count=final_state.phytomer_count,
    lai=final_state.lai,
    ftsw=final_state.ftsw,
))])

output_path = isempty(ARGS) ? joinpath(@__DIR__, "latest.csv") : only(ARGS)
CSV.write(output_path, record)
record
