using PlantSimEngine
# Include the example dummy processes:
using PlantSimEngine.Examples
using Test, Aqua
using Tables, DataFrames, CSV
using MultiScaleTreeGraph
using PlantMeteo, Statistics
using Documenter # for doctests

# There are 3 kinds of tests : 
# PSE functionality/feature tests
# Integration tests (launched in Github Actions, they run PBP and XPalm tests) 
# Benchmarks both internal and downstream, located in the downstream folder, and run in another Github Action

@testset "Testing PlantSimEngine" begin
    Aqua.test_all(PlantSimEngine, ambiguities=false)
    Aqua.test_ambiguities([PlantSimEngine])

    @testset "Unified scene/object API" begin
        include("test-unified-scene-object-api.jl")
    end

    @testset "ModelSpec Updates" begin
        include("test-updates.jl")
    end

    @testset "Meteo traits" begin
        include("test-meteo-traits.jl")
    end

    @testset "Environment backends" begin
        include("test-environment-backends.jl")
    end

    @testset "MAESPA-style scene example" begin
        include("test-maespa-scene-example.jl")
    end

    @testset "Status" begin
        include("test-Status.jl")
    end

    @testset "TimeStepTable" begin
        include("test-TimeStepTable.jl")
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

    if VERSION >= v"1.10"
        # Some formating changed in Julia 1.10, e.g. @NamedTuple instead of NamedTuple.
        @testset "Doctests" begin
            DocMeta.setdocmeta!(PlantSimEngine, :DocTestSetup, :(using PlantSimEngine, PlantMeteo, DataFrames); recursive=true)

            # Testing the doctests, i.e. the examples in the docstrings marked with jldoctest:
            doctest(PlantSimEngine; manual=false)
        end
    end
end
