using PlantSimEngine
realpath(pkgdir(PlantSimEngine)) == realpath(joinpath(@__DIR__, "..")) || error(
    "Tests must load this PlantSimEngine checkout; loaded $(pkgdir(PlantSimEngine)).",
)
using PlantSimEngine.Diagnostics
using PlantSimEngine.GraphEditor
using PlantSimEngine.EnvironmentAPI
using PlantSimEngine.Evaluation
# Include the example dummy processes:
using PlantSimEngine.Examples
using Test, Aqua
using Tables, DataFrames, CSV
using MultiScaleTreeGraph
using PlantMeteo, Statistics
using HTTP
using JSON
using Documenter # for doctests

# There are 3 kinds of tests:
# PSE functionality/feature tests
# Integration tests (launched in GitHub Actions for PlantBiophysics, XPalm, and PlantGeom)
# Benchmarks both internal and downstream, located in the downstream folder, and run in another GitHub Action

if length(ARGS) == 1 && endswith(only(ARGS), ".jl")
    focused_file = basename(only(ARGS))
    focused_path = joinpath(@__DIR__, focused_file)
    isfile(focused_path) || error("Unknown focused test file `$(focused_file)`.")
    @testset "Focused: $(focused_file)" begin
        if focused_file in ("test-model-prepared-call-vector-api.jl",
            "test-model-prepared-missing-future-schema.jl")
            include("test-model-prepared-call-schemas.jl")
        end
        include(focused_path)
    end
else
    include("test_groups.jl")
    shard_count = parse(Int, get(ENV, "PSE_TEST_SHARD_COUNT", "1"))
    shard_index = parse(Int, get(ENV, "PSE_TEST_SHARD_INDEX", "1"))
    1 <= shard_index <= shard_count <= length(TEST_GROUPS) ||
        error("Test shard index/count must satisfy 1 <= index <= count <= $(length(TEST_GROUPS)).")
    group_indices = shard_index:shard_count:length(TEST_GROUPS)
    @info "Test partition" shard_index shard_count groups=length(group_indices)

    @testset "Testing PlantSimEngine" begin
        if shard_index == 1
            Aqua.test_all(PlantSimEngine, ambiguities=false)
            Aqua.test_ambiguities([PlantSimEngine])
        end

        for group_index in group_indices
            name, files = TEST_GROUPS[group_index]
            @info "Test group start" group_index name files
            group_started_at = time_ns()
            try
                @testset "$name" begin
                    for file in files
                        include(file)
                    end
                end
            finally
                @info "Test group end" group_index name elapsed_seconds=(time_ns() - group_started_at) / 1.0e9
            end
        end

        if shard_index == 1
            @testset "Doctests" begin
                DocMeta.setdocmeta!(PlantSimEngine, :DocTestSetup,
                    :(using PlantSimEngine, PlantMeteo, DataFrames); recursive=true)
                doctest(PlantSimEngine; manual=false)
            end
        end
    end
end
