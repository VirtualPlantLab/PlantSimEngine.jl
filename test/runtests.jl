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
        include(focused_path)
    end
else
    @testset "Testing PlantSimEngine" begin
    Aqua.test_all(PlantSimEngine, ambiguities=false)
    Aqua.test_ambiguities([PlantSimEngine])

    @testset "Unified model/object API" begin
        include("test-unified-model-object-api.jl")
    end

    @testset "Experimental local execution interfaces" begin
        include("test-model-execution-interfaces.jl")
    end

    @testset "Experimental shared execution plans" begin
        include("test-model-shared-plan-prototype.jl")
    end

    @testset "Registered object identity" begin
        include("test-model-object-id.jl")
    end

    @testset "Organ creation allocations" begin
        include("test-organ-creation-allocation.jl")
    end

    @testset "Lifecycle snapshot allocations" begin
        include("test-lifecycle-snapshot-allocations.jl")
    end

    @testset "Organ status assembly" begin
        include("test-organ-status-assembly.jl")
    end

    @testset "CompositeModel display" begin
        include("test-model-display.jl")
    end

    @testset "Composite Model/Object API stabilization" begin
        include("test-model-api-stabilization.jl")
    end

    @testset "Selector candidate scope fast path" begin
        include("test-selector-candidate-empty-scope.jl")
    end

    @testset "Lifecycle without target additions" begin
        include("test-model-lifecycle-empty-targets.jl")
    end

    @testset "Cold execution target identity scans" begin
        include("test-execution-target-identities.jl")
    end

    @testset "Public model authoring API" begin
        include("test-authoring-api.jl")
    end

    @testset "Process authoring tutorial" begin
        include("test-process-generation.jl")
    end

    @testset "Packaged PlantSimEngine agent skill" begin
        include("test-agent-skill.jl")
    end

    @testset "Readable CompositeModel source" begin
        include("test-model-source-compilation.jl")
    end

    @testset "Composite model hard calls" begin
        include("test-model-hard-calls.jl")
    end

    @testset "Accepted call evaluations" begin
        include("test-model-call-evaluations.jl")
        include("test-call-evaluation-parent-generation.jl")
    end

    @testset "Prepared environment inputs" begin
        include("test-prepared-environment-inputs.jl")
    end

    @testset "Coalesced growth and environment invalidation" begin
        include("test-model-coalesced-growth-environment.jl")
    end

    @testset "Transient manual-call context reuse" begin
        include("test-model-call-context-cache.jl")
    end

    @testset "Lightweight manual-call target views" begin
        include("test-model-lightweight-call-targets.jl")
    end

    @testset "Collected hard-call target types" begin
        include("test-model-collected-call-targets.jl")
    end

    @testset "Reusable scoped hard-call targets" begin
        include("test-model-reusable-call-targets.jl")
    end

    @testset "Materialized manual-call dispatch" begin
        include("test-model-materialized-call-dispatch.jl")
    end

    @testset "Singular manual-call snapshot cache" begin
        include("test-model-single-call-snapshot-cache.jl")
    end

    @testset "Singular manual-call target access" begin
        include("test-model-only-call-targets.jl")
    end

    @testset "Individual manual-call environments" begin
        include("test-model-individual-call-environments.jl")
    end

    @testset "Individual environments in generated source" begin
        include("test-model-individual-source-environment.jl")
    end

    @testset "Newborn retained manual calls" begin
        include("test-model-newborn-retention.jl")
    end

    @testset "Scheduled newborn initializers" begin
        include("test-model-initializers.jl")
    end

    @testset "Composite model numerical parity" begin
        include("test-model-numerical-parity.jl")
    end

    @testset "Composite model status initialization" begin
        include("test-model-status-initialization.jl")
    end

    @testset "Initial status preparation" begin
        include("test-initial-status-preparation.jl")
    end

    @testset "Manual producers in Many inputs" begin
        include("test-manual-many-input-filter.jl")
    end

    @testset "Composite model status type conversion" begin
        include("test-model-status-type-conversion.jl")
    end

    @testset "Composite model status type conversion runtime" begin
        include("test-model-status-type-runtime.jl")
    end

    @testset "Composite model status type conversion lifecycle" begin
        include("test-model-status-type-lifecycle.jl")
    end

    @testset "Composite model status type conversion temporal policies" begin
        include("test-model-status-type-temporal.jl")
    end

    @testset "Composite model status type conversion with particles" begin
        include("test-model-status-type-particles.jl")
    end

    @testset "Composite model status type conversion templates" begin
        include("test-model-status-type-templates.jl")
    end

    @testset "Composite model status type conversion performance" begin
        include("test-model-status-type-performance.jl")
    end

    @testset "Composite model output boundaries" begin
        include("test-model-output-boundaries.jl")
    end

    @testset "Composite model output datetimes" begin
        include("test-model-output-datetime.jl")
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

    @testset "Compile-local output name metadata" begin
        include("test-model-input-plan-output-metadata.jl")
    end

    @testset "Adaptive subtree selectors" begin
        include("test-model-adaptive-selectors.jl")
    end

    @testset "Identity-aware Many inputs" begin
        include("test-model-bound-many.jl")
    end

    @testset "Column-backed reference carriers" begin
        include("test-model-column-reference-carriers.jl")
    end

    @testset "Distributed output declarations" begin
        include("test-model-output-destination-declarations.jl")
    end

    @testset "Distributed output runtime" begin
        include("test-model-distributed-output-runtime.jl")
    end

    @testset "Distributed output assignment API" begin
        include("test-model-output-targets-api.jl")
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

    @testset "Two-plant allocation comparison" begin
        include("test-two-plant-allocation.jl")
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

    @testset "Readable-source call evaluation acceptance" begin
        include("test-model-source-call-evaluations.jl")
    end

    @testset "Temporal inputs inside call evaluations" begin
        include("test-model-call-evaluation-temporal-inputs.jl")
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
