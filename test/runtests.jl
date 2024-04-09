using PlantSimEngine
# Include the example dummy processes:
using PlantSimEngine.Examples
using Test, Aqua
using Tables, DataFrames, CSV
using MultiScaleTreeGraph
using PlantMeteo, Statistics
using Documenter # for doctests

@testset "Testing PlantSimEngine" begin
    Aqua.test_all(PlantSimEngine, ambiguities=false)
    Aqua.test_ambiguities([PlantSimEngine])

    @testset "ModelList" begin
        include("test-ModelList.jl")
    end

    @testset "ModelList" begin
        include("test-mapping.jl")
    end

    @testset "MultiScaleModel" begin
        include("test-MultiScaleModel.jl")
    end

    @testset "Status" begin
        include("test-Status.jl")
    end

    @testset "TimeStepTable" begin
        include("test-TimeStepTable.jl")
    end

    @testset "Dimensions" begin
        include("test-dimensions.jl")
    end

    @testset "Simulations" begin
        include("test-simulation.jl")
    end

    @testset "Statistics" begin
        include("test-statistics.jl")
    end

    @testset "Fitting" begin
        include("test-fitting.jl")
    end

    @testset "Toy models" begin
        include("test-toy_models.jl")
    end

    @testset "MTG with multiscale mapping" begin
        include("test-mtg-multiscale.jl")
        include("test-mtg-dynamic.jl")
        include("test-mtg-multiscale-cyclic-dep.jl")
    end

    if VERSION >= v"1.10"
        # Some formating changed in Julia 1.10, e.g. @NamedTuple instead of NamedTuple.
        @testset "Doctests" begin
            DocMeta.setdocmeta!(PlantSimEngine, :DocTestSetup, :(using PlantSimEngine, PlantMeteo, DataFrames); recursive=true)

            # Testing the doctests, i.e. the examples in the docstrings marked with jldoctest:
            doctest(PlantSimEngine; manual=false)
        end
    end
end