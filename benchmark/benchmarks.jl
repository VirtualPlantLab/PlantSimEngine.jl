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
    include(joinpath(@__DIR__, "test-status-registry-benchmark.jl"))
    for nobjects in (32, 256, 1_024)
        SUITE[suite_name]["PSE_status_registry_lookup_$(nobjects)"] =
            @benchmarkable benchmark_status_registry_lookup(
                data.model,
                data.lookup_status,
            ) setup = (data = setup_status_registry_benchmark($nobjects))
        SUITE[suite_name]["PSE_status_registry_sweep_$(nobjects)"] =
            @benchmarkable benchmark_status_registry_sweep_checksum(
                data.model,
                data.statuses,
            ) setup = (data = setup_status_registry_benchmark($nobjects))
    end

    include(joinpath(@__DIR__, "test-selector-resolution-benchmark.jl"))
    const SELECTOR_RESOLUTION_BENCHMARK_PHYTOMERS = 2_048
    SUITE[suite_name]["PSE_selector_subtree_tip_2048"] =
        @benchmarkable benchmark_subtree_selector_resolution(
            data,
            data.tip_context,
        ) setup = (data = setup_subtree_selector_resolution_benchmark(
            $SELECTOR_RESOLUTION_BENCHMARK_PHYTOMERS,
        ))
    SUITE[suite_name]["PSE_selector_subtree_root_2048"] =
        @benchmarkable benchmark_subtree_selector_resolution(
            data,
            data.root_context,
        ) setup = (data = setup_subtree_selector_resolution_benchmark(
            $SELECTOR_RESOLUTION_BENCHMARK_PHYTOMERS,
        ))

    include(joinpath(@__DIR__, "test-organ-lifecycle-benchmark.jl"))
    for nobjects in (32, 256, 1_024)
        SUITE[suite_name]["PSE_organ_adaptation_$(nobjects)"] =
            @benchmarkable benchmark_adapt_organ_model(
                topology,
            ) setup = (topology = setup_organ_topology_benchmark(
                $nobjects,
            )) evals = 1
        SUITE[suite_name]["PSE_organ_add_$(nobjects)"] =
            @benchmarkable benchmark_add_organ!(
                data,
            ) setup = (data = setup_organ_lifecycle_benchmark(
                $nobjects,
            )) evals = 1
        SUITE[suite_name]["PSE_organ_refresh_$(nobjects)"] =
            @benchmarkable benchmark_refresh_after_add!(
                data,
            ) setup = (data = setup_organ_refresh_benchmark(
                $nobjects,
            )) evals = 1
        SUITE[suite_name]["PSE_organ_status_recipe_refresh_$(nobjects)"] =
            @benchmarkable benchmark_status_recipe_refresh_after_add!(
                data,
            ) setup = (data = setup_organ_status_recipe_refresh_benchmark(
                $nobjects,
            )) evals = 1
        SUITE[suite_name]["PSE_organ_add_refresh_$(nobjects)"] =
            @benchmarkable benchmark_add_and_refresh!(
                data,
            ) setup = (data = setup_organ_lifecycle_benchmark(
                $nobjects,
            )) evals = 1
        SUITE[suite_name]["PSE_organ_add_continue_$(nobjects)"] =
            @benchmarkable benchmark_add_and_continue!(
                data,
            ) setup = (data = setup_organ_lifecycle_benchmark(
                $nobjects;
                start_simulation=true,
            )) evals = 1
    end

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

    include(joinpath(@__DIR__, "test-immutable-scenario-benchmark.jl"))
    for output_policy in (:none, :requests, :all)
        SUITE[suite_name]["PSE_immutable_scenario_$(output_policy)"] =
            @benchmarkable benchmark_immutable_scenario_steps(
                simulation,
                48,
            ) setup = (simulation = setup_immutable_scenario_benchmark(
                nleaves=256,
                output_policy=$output_policy,
            )) evals = 1
    end
    SUITE[suite_name]["PSE_many_cadence_schedule"] =
        @benchmarkable benchmark_many_cadence_schedule(
            simulation,
            nsteps,
        ) setup = ((simulation, nsteps) =
            setup_many_cadence_schedule_benchmark()) evals = 1

    include(joinpath(@__DIR__, "test-distributed-output-benchmark.jl"))
    for nobjects in (1_000, 100_000)
        SUITE[suite_name]["PSE_refvector_sum_$(nobjects)"] =
            @benchmarkable benchmark_distributed_output_sum(
                values,
            ) setup = (values = setup_distributed_output_benchmark(
                $nobjects,
            ).ref_values)
        SUITE[suite_name]["PSE_bound_many_sum_$(nobjects)"] =
            @benchmarkable benchmark_distributed_output_sum(
                values,
            ) setup = (values = setup_distributed_output_benchmark(
                $nobjects,
            ).bound_values)
        SUITE[suite_name]["PSE_objectref_sum_$(nobjects)"] =
            @benchmarkable benchmark_distributed_output_sum(
                values,
            ) setup = (values = setup_distributed_output_benchmark(
                $nobjects,
            ).heterogeneous_values)
        SUITE[suite_name]["PSE_bound_objectref_sum_$(nobjects)"] =
            @benchmarkable benchmark_distributed_output_sum(
                values,
            ) setup = (values = setup_distributed_output_benchmark(
                $nobjects,
            ).bound_heterogeneous_values)
    end
    for nobjects in (10, 1_000, 10_000, 100_000)
        SUITE[suite_name]["PSE_distributed_assign_exact_$(nobjects)"] =
            @benchmarkable benchmark_assign_distributed_outputs_exact!(
                data.exact_targets,
                data.exact_values,
            ) setup = (data = setup_distributed_output_benchmark($nobjects))
        SUITE[suite_name]["PSE_distributed_assign_permuted_$(nobjects)"] =
            @benchmarkable benchmark_assign_distributed_outputs_permuted!(
                data.permuted_targets,
                data.permuted_values,
                data.result_to_destination,
            ) setup = (data = setup_distributed_output_benchmark($nobjects))
    end
    for nobjects in (10, 1_000, 10_000)
        SUITE[suite_name]["PSE_distributed_assign_status_$(nobjects)"] =
            @benchmarkable benchmark_assign_distributed_outputs_statuses_exact!(
                data.statuses,
                data.exact_values,
            ) setup = (data = setup_distributed_output_benchmark($nobjects))
        SUITE[suite_name]["PSE_distributed_assign_broadcast_$(nobjects)"] =
            @benchmarkable benchmark_assign_distributed_outputs_broadcast!(
                data.status_targets,
                data.exact_values,
            ) setup = (data = setup_distributed_output_benchmark($nobjects))
        SUITE[suite_name]["PSE_distributed_assign_columns_$(nobjects)"] =
            @benchmarkable benchmark_assign_distributed_output_columns_exact!(
                data.column_targets,
                data.column_values,
            ) setup = (data = setup_distributed_output_benchmark($nobjects))
        SUITE[suite_name]["PSE_distributed_assign_sparse_$(nobjects)"] =
            @benchmarkable benchmark_assign_distributed_outputs_permuted!(
                data.sparse_targets,
                data.sparse_values,
                data.sparse_result_to_destination,
            ) setup = (data = setup_distributed_output_benchmark($nobjects))
        SUITE[suite_name]["PSE_distributed_assign_heterogeneous_$(nobjects)"] =
            @benchmarkable benchmark_assign_distributed_outputs_exact!(
                data.heterogeneous_targets,
                data.exact_values,
            ) setup = (data = setup_distributed_output_benchmark($nobjects))
        SUITE[suite_name]["PSE_distributed_mapping_refresh_$(nobjects)"] =
            @benchmarkable benchmark_refresh_distributed_output_assignment_mapping(
                destination_ids,
                result_ids,
            ) setup = ((destination_ids, result_ids) =
                setup_distributed_output_mapping_refresh_benchmark($nobjects))
        SUITE[suite_name]["PSE_assign_outputs_control_$(nobjects)"] =
            @benchmarkable benchmark_distributed_output_public_assignment_step(
                simulation,
            ) setup = (simulation =
                setup_distributed_output_assignment_control_benchmark(
                    $nobjects,
                )) evals = 1
    end
    if isdefined(PlantSimEngine, :output_targets) &&
       isdefined(PlantSimEngine, :assign_outputs!)
        for nobjects in (10, 1_000, 10_000), order in (:exact, :permuted)
            assignment_paths = order === :exact ?
                               (:table, :columns, :ref_loop, :broadcast) :
                               (:table, :columns)
            for path in assignment_paths
                SUITE[suite_name]["PSE_assign_outputs_$(path)_$(order)_$(nobjects)"] =
                    @benchmarkable benchmark_distributed_output_public_assignment_step(
                        simulation,
                    ) setup = (simulation =
                        setup_distributed_output_public_assignment_benchmark(
                            $nobjects;
                            order=$order,
                            path=$path,
                )) evals = 1
            end
        end
        for nobjects in (10, 1_000, 10_000), order in (:exact, :permuted)
            assignment_paths = order === :exact ?
                               (:table, :columns, :ref_loop) :
                               (:table, :columns)
            for path in assignment_paths
                SUITE[suite_name]["PSE_assign_outputs_$(path)_2columns_$(order)_$(nobjects)"] =
                    @benchmarkable benchmark_distributed_output_public_assignment_step(
                        simulation,
                    ) setup = (simulation =
                        setup_distributed_output_public_assignment_benchmark(
                            $nobjects;
                            order=$order,
                            path=$path,
                            ncolumns=2,
                        )) evals = 1
            end
        end
        for nobjects in (10, 1_000, 10_000), path in (:columns, :ref_loop)
            SUITE[suite_name]["PSE_assign_outputs_$(path)_heterogeneous_exact_$(nobjects)"] =
                @benchmarkable benchmark_distributed_output_public_assignment_step(
                    simulation,
                ) setup = (simulation =
                    setup_distributed_output_public_assignment_benchmark(
                        $nobjects;
                        order=:exact,
                        path=$path,
                        heterogeneous=true,
                )) evals = 1
        end
        for ncolumns in (7, 19)
            SUITE[suite_name]["PSE_assign_outputs_columns_$(ncolumns)columns_exact_1000"] =
                @benchmarkable benchmark_distributed_output_public_assignment_step(
                    simulation,
                ) setup = (simulation =
                    setup_distributed_output_wide_assignment_benchmark(
                        1_000;
                        ncolumns=$ncolumns,
                    )) evals = 1
        end
    end
    SUITE[suite_name]["PSE_distributed_compile_permutation_1000"] =
        @benchmarkable compile_distributed_output_benchmark_permutation(
            data.object_ids,
            data.permuted_result_ids,
        ) setup = (data = setup_distributed_output_benchmark(1_000))
    for distributed in (false, true)
        compile_kind = distributed ? "active" : "none"
        SUITE[suite_name]["PSE_distributed_compile_$(compile_kind)_1000"] =
            @benchmarkable benchmark_compile_distributed_output_model(
                model,
            ) setup = (model = setup_distributed_output_compilation_benchmark(
                1_000;
                distributed=$distributed,
            )) evals = 1
    end
    SUITE[suite_name]["PSE_distributed_lifecycle_add_1000"] =
        @benchmarkable benchmark_refresh_distributed_output_lifecycle!(
            model,
            new_index,
        ) setup = ((model, new_index) =
            setup_distributed_output_lifecycle_benchmark(1_000)) evals = 1
    for identity_aware in (false, true)
        input_kind = identity_aware ? "bound" : "status"
        SUITE[suite_name]["PSE_$(input_kind)_many_input_steps_1000"] =
            @benchmarkable benchmark_distributed_output_input_steps(
                simulation,
                nsteps,
            ) setup = ((simulation, nsteps) =
                setup_distributed_output_input_step_benchmark(
                    1_000;
                    identity_aware=$identity_aware,
                )) evals = 1
    end

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
    for (kind, repeats, target_count) in (
        (:singular, 1, 1),
        (:repeated, 8, 1),
        (:nested, 1, 1),
        (:many, 1, 1000),
        (:heterogeneous, 1, 2),
        (:sampled_environment, 1, 1),
        (:published, 1, 1),
    )
        SUITE[suite_name]["PSE_compiled_hard_call_$(kind)"] =
            @benchmarkable benchmark_compiled_hard_call(
                model,
                nsteps,
            ) setup = ((model, nsteps) =
                setup_compiled_hard_call_benchmark(
                    kind=$kind,
                    repeats=$repeats,
                    target_count=$target_count,
                ))
    end
    SUITE[suite_name]["PSE_call_binding_signature_4096"] =
        @benchmarkable benchmark_call_binding_signature(
            binding,
        ) setup = (binding = setup_call_binding_signature_benchmark(4_096))
    SUITE[suite_name]["PSE_lifecycle_small"] =
        @benchmarkable benchmark_lifecycle_event(
            simulation,
            new_index,
        ) setup = ((simulation, new_index) =
            setup_lifecycle_hard_call_benchmark(
                nobjects=32,
                usage=:zero,
                performance=false,
            ))
    SUITE[suite_name]["PSE_lifecycle_large"] =
        @benchmarkable benchmark_lifecycle_event(
            simulation,
            new_index,
        ) setup = ((simulation, new_index) =
            setup_lifecycle_hard_call_benchmark(
                nobjects=5000,
                usage=:zero,
                performance=false,
            ))
    SUITE[suite_name]["PSE_lifecycle_immediate_hard_call"] =
        @benchmarkable benchmark_lifecycle_event(
            simulation,
            new_index,
        ) setup = ((simulation, new_index) =
            setup_lifecycle_hard_call_benchmark(
                nobjects=1000,
                usage=:dense,
                performance=false,
            ))
end

if INCLUDE_DOWNSTREAM_BENCHMARKS &&
   SUPPORTS_COMPOSITE_OBJECT_BENCHMARKS
    # "PBP benchmark"
    include(joinpath(@__DIR__, "test-plantbiophysics.jl"))
    const PLANTBIOPHYSICS_PR_BENCHMARK_STEPS = 100
    SUITE[suite_name]["PBP_multistep_no_outputs"] =
        @benchmarkable benchmark_plantbiophysics_multistep(
            model,
            nsteps;
            outputs=:none,
        ) setup = ((model, nsteps) = setup_plantbiophysics_multistep(
            nsteps=PLANTBIOPHYSICS_PR_BENCHMARK_STEPS,
        ))
    SUITE[suite_name]["PBP_multistep_all_outputs"] =
        @benchmarkable benchmark_plantbiophysics_multistep(
            model,
            nsteps;
            outputs=:all,
        ) setup = ((model, nsteps) = setup_plantbiophysics_multistep(
            nsteps=PLANTBIOPHYSICS_PR_BENCHMARK_STEPS,
        ))
    SUITE[suite_name]["PBP_construction"] =
        @benchmarkable setup_plantbiophysics_multistep(
            nsteps=PLANTBIOPHYSICS_PR_BENCHMARK_STEPS,
        )
    SUITE[suite_name]["PBP_one_step_fanout"] =
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
