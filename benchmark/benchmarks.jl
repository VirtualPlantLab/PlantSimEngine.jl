using Pkg
Pkg.activate(dirname(@__FILE__))
#Pkg.develop(PackageSpec(path=dirname(dirname(@__DIR__))))
Pkg.add(url="https://github.com/VEZY/PlantBiophysics.jl", rev="master")
Pkg.add(url="https://github.com/PalmStudio/XPalm.jl", rev="main")
Pkg.resolve()
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
const SUITE = BenchmarkGroup()
SUITE[suite_name] = BenchmarkGroup(["PSE", "PBP", "XPalm"])

# "PSE benchmark"
include("test-PSE-benchmark.jl")
SUITE[suite_name]["PSE"] = @benchmarkable do_benchmark_on_heavier_mtg()

# "PBP benchmark"
include("test-plantbiophysics.jl")
SUITE[suite_name]["PBP"] = @benchmarkable benchmark_plantbiophysics()

leaf, meteo = setup_benchmark_plantbiophysics_multitimestep()
SUITE[suite_name]["PBP_multiple_timesteps_MT"] = @benchmarkable benchmark_plantbiophysics_multitimestep_MT($leaf, $meteo)
SUITE[suite_name]["PBP_multiple_timesteps_ST"] = @benchmarkable benchmark_plantbiophysics_multitimestep_ST($leaf, $meteo)

# "XPalm benchmark" 
include("test-xpalm.jl")
SUITE[suite_name]["XPalm_setup"] = @benchmarkable xpalm_default_param_create() seconds = 120

palm, models, out_vars, meteo = xpalm_default_param_create()
sim_outputs = xpalm_default_param_run(palm, models, out_vars, meteo)

SUITE[suite_name]["XPalm_run"] = @benchmarkable xpalm_default_param_run($palm, $models, $out_vars, $meteo) seconds = 120
SUITE[suite_name]["XPalm_convert_outputs"] = @benchmarkable xpalm_default_param_convert_outputs($sim_outputs) seconds = 120

#tune!(SUITE)
#results = run(SUITE, verbose=true)
#BenchmarkTools.save(dirname(@__FILE__) * "/output.json", median(results))