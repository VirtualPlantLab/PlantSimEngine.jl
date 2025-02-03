using Pkg
Pkg.activate(dirname(@__FILE__))
Pkg.develop(PackageSpec(path=dirname(dirname(@__DIR__))))
Pkg.instantiate()

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
suite = BenchmarkGroup()
suite[suite_name] = BenchmarkGroup(["PSE", "PBP"])#, "XPalm"])

# "PSE benchmark"
include("test-PSE-benchmark.jl")
suite[suite_name]["PSE"] = @benchmarkable do_benchmark_on_heavier_mtg()

# "PBP benchmark"
include("test-plantbiophysics.jl")
suite[suite_name]["PBP"] = @benchmarkable benchmark_plantbiophysics()

leaf, meteo = setup_benchmark_plantbiophysics_multitimestep()
suite[suite_name]["PBP_multiple_timesteps_MT"] = @benchmarkable benchmark_plantbiophysics_multitimestep_MT($leaf, $meteo)
suite[suite_name]["PBP_multiple_timesteps_ST"] = @benchmarkable benchmark_plantbiophysics_multitimestep_ST($leaf, $meteo)

# "XPalm benchmark" 
#include("test-xpalm.jl")
#suite[suite_name]["XPalm"] = @benchmarkable xpalm_default_param_run() seconds = 120

tune!(suite)
results = run(suite, verbose=true)
BenchmarkTools.save(dirname(@__FILE__) * "/output.json", median(results))