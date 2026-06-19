using Test

ENV["PLANTSIMENGINE_DOCS_BUILD_ONLY"] = "true"
include(joinpath(@__DIR__, "..", "make.jl"))

@testset "documentation build" begin
    @test isdir(joinpath(@__DIR__, "..", "build"))
end
