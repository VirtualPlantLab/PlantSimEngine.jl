using PlantSimEngine
# Include the example dummy processes:
using PlantSimEngine.Examples
using Test, Aqua
using Tables, DataFrames, CSV
using MultiScaleTreeGraph
using PlantMeteo, Statistics
using HTTP
using JSON
using Documenter # for doctests

# There are 3 kinds of tests : 
# PSE functionality/feature tests
# Integration tests (launched in Github Actions, they run PBP and XPalm tests) 
# Benchmarks both internal and downstream, located in the downstream folder, and run in another Github Action

if length(ARGS) == 1 && endswith(only(ARGS), ".jl")
    focused_file = basename(only(ARGS))
    focused_path = joinpath(@__DIR__, focused_file)
    isfile(focused_path) || error("Unknown focused test file `$(focused_file)`.")
    @testset "Focused: $(focused_file)" begin
        include(focused_path)
    end
else
    @testset "Testing PlantSimEngine" begin
    Aqua.test_all(PlantSimEngine, ambiguities=false)
    Aqua.test_ambiguities([PlantSimEngine])

    @testset "Unified scene/object API" begin
        include("test-unified-scene-object-api.jl")
    end

    @testset "Scene/Object API stabilization" begin
        include("test-scene-api-stabilization.jl")
    end

    @testset "Scene hard calls" begin
        include("test-scene-hard-calls.jl")
    end

    @testset "Scene numerical parity" begin
        include("test-scene-numerical-parity.jl")
    end

    @testset "Scene status initialization" begin
        include("test-scene-status-initialization.jl")
    end

    @testset "Scene output boundaries" begin
        include("test-scene-output-boundaries.jl")
    end

    @testset "Scene time validation" begin
        include("test-scene-time-validation.jl")
    end

    @testset "Scene runtime matrix" begin
        include("test-scene-runtime-matrix.jl")
    end

    @testset "Scene meteorological sampling" begin
        include("test-scene-meteo-sampling.jl")
    end

    @testset "Scene temporal reducers" begin
        include("test-scene-temporal-reducers.jl")
    end

    @testset "Scene binding inference" begin
        include("test-scene-binding-inference.jl")
    end

    @testset "Scene multirate integration" begin
        include("test-scene-multirate-integration.jl")
    end

    @testset "Scene configuration errors" begin
        include("test-scene-configuration-errors.jl")
    end

    @testset "Scene graph viewer" begin
        include("test-scene-graph-view.jl")
    end

    @testset "Scene graph editor extension" begin
        include("test-scene-graph-editor-extension.jl")
    end

    @testset "Model contract" begin
        include("test-model-contract.jl")
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
end
