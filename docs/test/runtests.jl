using Test

@testset "PlantSimEngine documentation" begin
    ENV["PLANTSIMENGINE_DOCS_BUILD_ONLY"] = "true"
    @test include(joinpath(@__DIR__, "..", "make.jl")) === nothing
end
