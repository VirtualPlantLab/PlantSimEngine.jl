using PlantSimEngine
using PlantSimEngine.Examples
using DataFrames, CSV
using MultiScaleTreeGraph
using PlantMeteo, Statistics

using BenchmarkTools
using Dates

suite_name = "bench_"

if Sys.iswindows()
    suite_name = suite_name * "windows"
elseif Sys.isapple()
    suite_name = suite_name * "mac"
elseif Sys.islinux()
    suite_name = suite_name * "linux"
end
const SUITE = BenchmarkGroup()
const INCLUDE_DOWNSTREAM_BENCHMARKS = get(
    ENV,
    "PSE_BENCHMARK_INCLUDE_DOWNSTREAM",
    get(ENV, "GITHUB_ACTIONS", "false") == "true" ? "false" : "true",
) == "true"
_supports_composite_object_benchmarks(engine) =
    isdefined(engine, :CompositeModel) &&
    isdefined(engine, :Object) &&
    isdefined(engine, :RunContext)
const SUPPORTS_COMPOSITE_OBJECT_BENCHMARKS =
    get(ENV, "PSE_BENCHMARK_FORCE_LEGACY_BASELINE", "false") != "true" &&
    _supports_composite_object_benchmarks(PlantSimEngine)
SUITE[suite_name] = BenchmarkGroup(
    INCLUDE_DOWNSTREAM_BENCHMARKS &&
    SUPPORTS_COMPOSITE_OBJECT_BENCHMARKS ?
    ["PSE", "PBP", "XPalm"] : ["PSE"],
)
SUITE[suite_name]["PSE_status_read_write"] = @benchmarkable begin
    status.value += 1.0
    status.value
end setup = (status = PlantSimEngine.Status(value=0.0))

if SUPPORTS_COMPOSITE_OBJECT_BENCHMARKS
    # Composite-model benchmarks cannot be constructed while AirspeedVelocity
    # evaluates this script against a pre-CompositeModel baseline revision.
    include(joinpath(@__DIR__, "test-PSE-benchmark.jl"))
    SUITE[suite_name]["PSE"] = @benchmarkable benchmark_heavier_scene(
        model,
        requests,
        nsteps,
    ) setup = ((model, requests, nsteps) = setup_heavier_model_benchmark())

    include(joinpath(@__DIR__, "test-multirate-buffer-benchmark.jl"))
    SUITE[suite_name]["PSE_multirate_retain_all_run"] = @benchmarkable benchmark_multirate_retain_all_run(
        model,
        nsteps,
    ) setup = ((model, ignored_requests, nsteps) = setup_multirate_buffer_benchmark())
    SUITE[suite_name]["PSE_multirate_output_request_run"] = @benchmarkable benchmark_multirate_output_request_run(
        model,
        requests,
        nsteps,
    ) setup = ((model, requests, nsteps) = setup_multirate_buffer_benchmark())
    SUITE[suite_name]["PSE_multirate_no_output_run"] = @benchmarkable benchmark_multirate_no_output_run(
        model,
        nsteps,
    ) setup = ((model, ignored_requests, nsteps) = setup_multirate_buffer_benchmark())

    include(joinpath(@__DIR__, "test-hard-call-path-benchmark.jl"))
    for usage in (:zero, :sparse, :dense)
        SUITE[suite_name]["PSE_hard_calls_$(usage)"] =
            @benchmarkable benchmark_hard_call_path(
                model,
                nsteps,
            ) setup = ((model, nsteps) = setup_hard_call_path_benchmark(
                usage=$usage,
            ))
    end
    SUITE[suite_name]["PSE_lifecycle_small"] =
        @benchmarkable benchmark_lifecycle_event(
            simulation,
            new_index,
        ) setup = ((simulation, new_index) =
            setup_lifecycle_hard_call_benchmark(
                nobjects=32,
                usage=:zero,
            ))
    SUITE[suite_name]["PSE_lifecycle_large"] =
        @benchmarkable benchmark_lifecycle_event(
            simulation,
            new_index,
        ) setup = ((simulation, new_index) =
            setup_lifecycle_hard_call_benchmark(
                nobjects=5000,
                usage=:zero,
            ))
    SUITE[suite_name]["PSE_lifecycle_immediate_hard_call"] =
        @benchmarkable benchmark_lifecycle_event(
            simulation,
            new_index,
        ) setup = ((simulation, new_index) =
            setup_lifecycle_hard_call_benchmark(
                nobjects=1000,
                usage=:dense,
            ))
end

if INCLUDE_DOWNSTREAM_BENCHMARKS &&
   SUPPORTS_COMPOSITE_OBJECT_BENCHMARKS
    # "PBP benchmark"
    include(joinpath(@__DIR__, "test-plantbiophysics.jl"))
    SUITE[suite_name]["PBP"] = @benchmarkable benchmark_plantbiophysics()
    SUITE[suite_name]["PBP_batch_run"] =
        @benchmarkable benchmark_plantbiophysics_batch(
            scenes,
        ) setup = (scenes = setup_benchmark_plantbiophysics_batch())

    # "XPalm benchmark"
    include(joinpath(@__DIR__, "test-xpalm.jl"))
    include(joinpath(@__DIR__, "performance_regression.jl"))
    const XPALM_PR_BENCHMARK_STEPS = 100
    SUITE[suite_name]["XPalm_setup_100"] =
        @benchmarkable xpalm_default_param_create(
            nsteps=XPALM_PR_BENCHMARK_STEPS,
        ) seconds = 30

    SUITE[suite_name]["XPalm_run_100"] =
        @benchmarkable xpalm_default_param_run(
            model,
            requests,
            nsteps,
        ) setup = ((model, requests, nsteps) = xpalm_default_param_create(;
            nsteps=XPALM_PR_BENCHMARK_STEPS,
        ))

    SUITE[suite_name]["XPalm_reference_outputs_100"] =
        @benchmarkable xpalm_reference_param_run(
            model,
            requests,
            nsteps,
        ) setup = ((model, requests, nsteps) = xpalm_reference_param_create(;
            nsteps=XPALM_PR_BENCHMARK_STEPS,
        ))

    SUITE[suite_name]["XPalm_no_outputs_100"] =
        @benchmarkable xpalm_reference_param_run(
            model,
            requests,
            nsteps;
            outputs=:none,
        ) setup = ((model, requests, nsteps) = xpalm_reference_param_create(;
            nsteps=XPALM_PR_BENCHMARK_STEPS,
        ))

    SUITE[suite_name]["XPalm_small_outputs_100"] =
        @benchmarkable xpalm_reference_param_run(
            model,
            requests,
            nsteps,
        ) setup = ((model, requests, nsteps) = xpalm_small_param_create(;
            nsteps=XPALM_PR_BENCHMARK_STEPS,
        ))

    SUITE[suite_name]["XPalm_all_outputs_100"] =
        @benchmarkable xpalm_reference_param_run(
            model,
            OutputRequest[],
            nsteps;
            outputs=:all,
        ) setup = ((model, nsteps) = xpalm_reference_model_create(;
            nsteps=XPALM_PR_BENCHMARK_STEPS,
        ))
end

if abspath(PROGRAM_FILE) == @__FILE__
    tune!(SUITE)
    results = run(SUITE; verbose=true)
    default_name =
        "benchmark-$(Dates.format(Dates.now(), dateformat"yyyymmdd-HHMMSS")).json"
    output_path = get(
        ENV,
        "PSE_BENCHMARK_OUTPUT",
        joinpath(@__DIR__, "results", default_name),
    )
    mkpath(dirname(output_path))
    BenchmarkTools.save(output_path, median(results))
    if INCLUDE_DOWNSTREAM_BENCHMARKS &&
       SUPPORTS_COMPOSITE_OBJECT_BENCHMARKS
        summary_path = replace(output_path, r"\.[^.]+$" => "-summary.csv")
        metadata = _performance_metadata(;
            warmup_policy="BenchmarkTools tune plus per-benchmark setup",
        )
        write_benchmark_summary(summary_path, results, metadata)
        @info "PlantSimEngine benchmark suite complete" output_path summary_path
    else
        @info "PlantSimEngine benchmark suite complete" output_path
    end
end
