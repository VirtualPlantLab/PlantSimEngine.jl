# Run only in a Kaimon-controlled session for this checkout. Optional package
# paths are local experiment inputs, not default benchmark dependencies.
using PlantSimEngine
for path in (
    "/Users/rvezy/Documents/dev/PlantSimEngine/benchmark",
    "/Users/rvezy/Documents/dev/PlantGeom",
    "/Users/rvezy/Documents/dev/PlantBiophysics",
    "/Users/rvezy/Documents/dev/XPalm",
)
    path in LOAD_PATH || push!(LOAD_PATH, path)
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
