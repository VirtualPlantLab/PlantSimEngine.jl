module NativeRoundCoreRegressions
using Dates, Test, MultiScaleTreeGraph, PlantSimEngine, PlantMeteo
using PlantSimEngine.Diagnostics

@testset "Existing feature regressions after native storage hooks" begin
    for file in (
        "test-organ-status-assembly.jl",
        "test-model-status-initialization.jl",
        "test-model-status-type-templates.jl",
        "test-model-status-type-temporal.jl",
        "test-model-initializers.jl",
        "test-model-distributed-output-runtime.jl",
        "test-model-column-reference-carriers.jl",
        "test-model-coalesced-growth-environment.jl",
    )
        include(joinpath(pkgdir(PlantSimEngine), "test", file))
    end
end
end
