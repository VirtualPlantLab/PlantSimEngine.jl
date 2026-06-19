using PlantSimEngine
using PlantSimEngine.Examples
using DataFrames, CSV
using MultiScaleTreeGraph
using PlantMeteo, Statistics

using BenchmarkTools
using Dates

suite_name = "bench_"

if Sys.iswindows()
    suite_name = suite_name * "windows"
elseif Sys.isapple()
    suite_name = suite_name * "mac"
elseif Sys.islinux()
    suite_name = suite_name * "linux"
end
const SUITE = BenchmarkGroup()
SUITE[suite_name] = BenchmarkGroup(["PSE", "PBP", "XPalm"])

# "PSE benchmark"
include(joinpath(@__DIR__, "test-PSE-benchmark.jl"))
SUITE[suite_name]["PSE"] = @benchmarkable benchmark_heavier_scene(
    scene,
    requests,
    nsteps,
) setup = ((scene, requests, nsteps) = setup_heavier_scene_benchmark())

include(joinpath(@__DIR__, "test-multirate-buffer-benchmark.jl"))
SUITE[suite_name]["PSE_multirate_retain_all_run"] = @benchmarkable benchmark_multirate_retain_all_run(
    scene,
    nsteps,
) setup = ((scene, ignored_requests, nsteps) = setup_multirate_buffer_benchmark())
SUITE[suite_name]["PSE_multirate_output_request_run"] = @benchmarkable benchmark_multirate_output_request_run(
    scene,
    requests,
    nsteps,
) setup = ((scene, requests, nsteps) = setup_multirate_buffer_benchmark())

# "PBP benchmark"
include(joinpath(@__DIR__, "test-plantbiophysics.jl"))
SUITE[suite_name]["PBP"] = @benchmarkable benchmark_plantbiophysics()
SUITE[suite_name]["PBP_batch_run"] = @benchmarkable benchmark_plantbiophysics_batch(
    scenes,
) setup = (scenes = setup_benchmark_plantbiophysics_batch())

# "XPalm benchmark" 
include(joinpath(@__DIR__, "test-xpalm.jl"))
SUITE[suite_name]["XPalm_setup"] = @benchmarkable xpalm_default_param_create() seconds = 120

SUITE[suite_name]["XPalm_run"] = @benchmarkable xpalm_default_param_run(
    scene,
    requests,
    nsteps,
) setup = ((scene, requests, nsteps) = xpalm_default_param_create())

#tune!(SUITE)
#results = run(SUITE, verbose=true)
#BenchmarkTools.save(dirname(@__FILE__) * "/output.json", median(results))
