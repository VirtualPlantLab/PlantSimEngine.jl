# Run only in a Kaimon-controlled session for this checkout. Optional package
# paths are local experiment inputs, not default benchmark dependencies.
using PlantSimEngine
let devroot=get(ENV, "PSE_DOWNSTREAM_DEV_ROOT", joinpath(homedir(), "Documents", "dev"))
    for (key, fallback) in (
        ("PSE_BENCHMARK_ENV_PATH", joinpath(devroot, "PlantSimEngine", "benchmark")),
        ("PSE_PLANTGEOM_PATH", joinpath(devroot, "PlantGeom")),
        ("PSE_PLANTBIOPHYSICS_PATH", joinpath(devroot, "PlantBiophysics")),
        ("PSE_XPALM_PATH", joinpath(devroot, "XPalm")),
    )
        path=get(ENV,key,fallback)
        isdir(path) && !(path in LOAD_PATH) && push!(LOAD_PATH,path)
    end
end
using PlantGeom, PlantBiophysics, XPalm
include(joinpath(@__DIR__, "../compiled_regions/CompiledRegionsExperiment.jl"))
include(joinpath(@__DIR__, "measurements.jl"))
include(joinpath(@__DIR__, "scalar_driver.jl"))
include(joinpath(@__DIR__, "pb_driver.jl"))
include(joinpath(@__DIR__, "xpalm_driver.jl"))
include(joinpath(@__DIR__, "generic_driver.jl"))
const CR = CompiledRegionsExperiment
const M = NativeDownstreamMeasurements
const NS = NativeScalarDriver
const NPB = NativePBDriver
const NXP = NativeXPDriver
const NG = NativeGenericDriver
