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

    @testset "Unified model/object API" begin
        include("test-unified-model-object-api.jl")
    end

    @testset "Composite Model/Object API stabilization" begin
        include("test-model-api-stabilization.jl")
    end

    @testset "Composite model hard calls" begin
        include("test-model-hard-calls.jl")
    end

    @testset "Composite model numerical parity" begin
        include("test-model-numerical-parity.jl")
    end

    @testset "Composite model status initialization" begin
        include("test-model-status-initialization.jl")
    end

    @testset "Composite model output boundaries" begin
        include("test-model-output-boundaries.jl")
    end

    @testset "Composite model time validation" begin
        include("test-model-time-validation.jl")
    end

    @testset "Composite model runtime matrix" begin
        include("test-model-runtime-matrix.jl")
    end

    @testset "Composite model environment sampling" begin
        include("test-model-environment-sampling.jl")
    end

    @testset "Composite model temporal reducers" begin
        include("test-model-temporal-reducers.jl")
    end

    @testset "PreviousTimeStep application-local status views" begin
        include("test-model-previous-timestep-views.jl")
    end

    @testset "Composite model binding inference" begin
        include("test-model-binding-inference.jl")
    end

    @testset "Composite model multirate integration" begin
        include("test-model-multirate-integration.jl")
    end

    @testset "Composite model configuration errors" begin
        include("test-model-configuration-errors.jl")
    end

    @testset "Model graph viewer" begin
        include("test-model-graph-view.jl")
    end

    @testset "Model graph editor extension" begin
        include("test-model-graph-editor-extension.jl")
    end

    @testset "Model contract" begin
        include("test-model-contract.jl")
    end

    @testset "ModelSpec Updates" begin
        include("test-updates.jl")
    end

    @testset "Environment traits" begin
        include("test-environment-traits.jl")
    end

    @testset "Environment backends" begin
        include("test-environment-backends.jl")
    end

    @testset "MAESPA-style model example" begin
        include("test-maespa-model-example.jl")
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
