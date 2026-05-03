using PlantSimEngine
# Include the example dummy processes:
using PlantSimEngine.Examples
using Test, Aqua
using Tables, DataFrames, CSV
using MultiScaleTreeGraph
using PlantMeteo, Statistics
using Documenter # for doctests

include("helper-functions.jl")

# There are 3 kinds of tests : 
# PSE functionality/feature tests
# Integration tests (launched in Github Actions, they run PBP and XPalm tests) 
# Benchmarks both internal and downstream, located in the downstream folder, and run in another Github Action

@testset "Testing PlantSimEngine" begin
    Aqua.test_all(PlantSimEngine, ambiguities=false)
    Aqua.test_ambiguities([PlantSimEngine])

    @testset "ModelMapping: single scale" begin
        include("test-ModelMapping.jl")
    end

    @testset "ModelMapping: multi scale" begin
        include("test-mapping.jl")
    end

    @testset "Multi-rate scaffolding" begin
        include("test-multirate-scaffolding.jl")
    end

    @testset "Multi-rate runtime" begin
        include("test-multirate-runtime.jl")
    end

    @testset "Multi-rate output export" begin
        include("test-multirate-output-export.jl")
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

    @testset "Compiled model source" begin
        include("test-compiled-model.jl")
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

    @testset "Multiscale corner-cases" begin
        include("test-corner-cases.jl")
    end

    @testset "Multithreading" begin
        include("test-performance.jl")
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
