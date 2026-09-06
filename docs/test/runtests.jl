using Test

@testset "Progressive journey structure" begin
    journey_root = joinpath(@__DIR__, "..", "src", "journeys")
    user_pages = sort([
        joinpath(journey_root, "users", file)
        for file in readdir(joinpath(journey_root, "users"))
        if endswith(file, ".md")
    ])
    modeler_pages = sort([
        joinpath(journey_root, "modelers", file)
        for file in readdir(joinpath(journey_root, "modelers"))
        if endswith(file, ".md")
    ])

    for page in user_pages
        source = read(page, String)
        @test occursin("New concept", source)
        @test occursin("## Page recap", source)
        @test occursin("**You added:**", source)
        @test occursin("**PlantSimEngine infer", source)
        @test occursin("**You keep explicit:**", source)
        @test occursin("**New API names:**", source)
        @test !occursin("```julia", source)
    end

    for page in modeler_pages
        source = read(page, String)
        @test occursin("**New concept:**", source)
        @test occursin("## Model-author recap", source)
        @test occursin("**You implemented:**", source)
        @test occursin("**PlantSimEngine inferred:**", source)
        @test occursin("**The scenario author keeps explicit:**", source)
        @test occursin("**New API names:**", source)
        @test occursin("tested", lowercase(source))
    end
end

@testset "PlantSimEngine documentation" begin
    ENV["PLANTSIMENGINE_DOCS_BUILD_ONLY"] = "true"
    @test include(joinpath(@__DIR__, "..", "make.jl")) === nothing
end
