(@__MODULE__) === Main || error(
    "Include call_growth_regressions.jl into Main so readable test sources can resolve their model modules.",
)

using Dates, PlantMeteo, PlantSimEngine, Test
using PlantSimEngine.Diagnostics
# Main may also have PlantGeom loaded by the downstream experiment loader.
# These tests exercise the PSE object accessor, resolving the export collision.
import PlantSimEngine: geometry

const CALL_GROWTH_REGRESSION_SOURCE_ROOT = realpath(joinpath(@__DIR__, "..", ".."))

# These existing ordinary-executor tests complement core_regressions.jl.
# They use toy kernels; the largest executed manual-call fixture has 128 targets
# (a separate metadata-only signature check constructs 4096 object IDs).
# Keep every complete file, including its allocation and identity assertions.
const CALL_GROWTH_ADDITIONAL_REGRESSION_FILES = (
    "test-model-lifecycle-empty-targets.jl",
    "test-model-multirate-integration.jl",
    "test-model-hard-calls.jl",
    "test-model-call-evaluations.jl",
    "test-model-call-context-cache.jl",
    "test-model-reusable-call-targets.jl",
    "test-model-individual-call-environments.jl",
    "test-model-newborn-retention.jl",
    "test-model-runtime-matrix.jl",
)

function _call_growth_with_uncaptured_streams(f)
    # Kaimon capture IO is not fd-backed. Test macros such as @test_nowarn
    # temporarily redirect stderr and must be able to restore a real stream.
    # Discover an already loaded gate without adding/importing a dependency.
    gate = nothing
    for (package_id, loaded) in Base.loaded_modules
        package_id.name == "KaimonGate" || continue
        gate = loaded
        break
    end
    if gate !== nothing && isdefined(gate, :_with_uncaptured_streams)
        return Base.invokelatest(getfield(gate, :_with_uncaptured_streams), f)
    end
    return f()
end

"""
    run_call_growth_regressions(; files=CALL_GROWTH_ADDITIONAL_REGRESSION_FILES,
        logfile=".../results/call-growth/ordinary-regressions.log")

Run unchanged existing tests in Main, using fd-backed stdout/stderr so test
capture macros also work under Kaimon. Inclusion only defines this runner;
tests run on an explicit call. Returns small aggregate counts and a log path.
`files` may select a subset of the nine listed files for a bounded rerun.
Any test failure/error is returned as `passed=false`; no test is filtered or
rewritten. Other exceptions and interrupts propagate normally.
"""
function run_call_growth_regressions(;
    files=CALL_GROWTH_ADDITIONAL_REGRESSION_FILES,
    logfile=joinpath(CALL_GROWTH_REGRESSION_SOURCE_ROOT, "benchmark", "native_downstream",
        "results", "call-growth", "ordinary-regressions.log"),
)
    realpath(pkgdir(PlantSimEngine)) == CALL_GROWTH_REGRESSION_SOURCE_ROOT || error(
        "Call/growth regressions must load this checkout; loaded $(pkgdir(PlantSimEngine)).",
    )
    selected = Tuple(String(file) for file in files)
    isempty(selected) && throw(ArgumentError("Select at least one regression file"))
    length(unique(selected)) == length(selected) || throw(ArgumentError(
        "Regression file selection must not contain duplicates"))
    all(file -> file in CALL_GROWTH_ADDITIONAL_REGRESSION_FILES, selected) ||
        throw(ArgumentError("Select only listed call/growth regression files"))
    logpath = abspath(logfile)
    mkpath(dirname(logpath))
    return _call_growth_with_uncaptured_streams() do
        open(logpath, "w") do io
            redirect_stdio(stdout=io, stderr=io) do
                recorded = Ref{Any}(nothing)
                try
                    @testset "Existing ordinary execution regressions after call/growth hooks" begin
                        recorded[] = Test.get_testset()
                        for file in selected
                            write(io, "BEGIN\t", file, '\n')
                            flush(io)
                            @testset "$file" begin
                                Base.include(Main, joinpath(CALL_GROWTH_REGRESSION_SOURCE_ROOT,
                                    "test", file))
                            end
                            write(io, "END\t", file, '\n')
                            flush(io)
                        end
                    end
                catch test_exception
                    test_exception isa Test.TestSetException || rethrow()
                    # The unchanged Test machinery has already recorded and
                    # logged every failed assertion/error in the outer set.
                end
                recorded[] === nothing && error("Regression test set was not recorded")
                counts = Test.get_test_counts(recorded[])
                passes = counts.passes + counts.cumulative_passes
                failures = counts.fails + counts.cumulative_fails
                errors = counts.errors + counts.cumulative_errors
                broken = counts.broken + counts.cumulative_broken
                flush(io)
                return (passed=iszero(failures) && iszero(errors), passes,
                    failures, errors, broken, duration=counts.duration,
                    files=collect(selected), logfile=logpath)
            end
        end
    end
end
