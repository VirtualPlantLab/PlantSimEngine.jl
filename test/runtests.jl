using PlantSimEngine
using Test, Aqua
using Tables, DataFrames
using MultiScaleTreeGraph
using PlantMeteo
using Documenter # for doctests

# Include the example dummy processes:
include("../examples/dummy.jl")


@testset "Testing PlantSimEngine" begin

    Aqua.test_all(
        PlantSimEngine,
        # Removing this test as dependencies return ambiguities...
        #! But do it sometimes just to check that there are no ambiguities!
        ambiguities=false
    )

    @testset "ModelList" begin
        include("test-ModelList.jl")
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

    @testset "Doctests" begin
        DocMeta.setdocmeta!(PlantSimEngine, :DocTestSetup, :(using PlantSimEngine, PlantMeteo, DataFrames); recursive=true)

        # Testing the doctests, i.e. the examples in the docstrings marked with jldoctest:
        doctest(PlantSimEngine; manual=false)
    end

end