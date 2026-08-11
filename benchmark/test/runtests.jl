using BenchmarkTools
using CSV
using DataFrames
using Dates
using MultiScaleTreeGraph
using PlantMeteo
using PlantSimEngine
using PlantSimEngine.Examples
using Profile
using Statistics
using Test
using TOML

const BENCHMARK_TEST_PATTERN =
    isempty(ARGS) ? nothing : Regex(only(ARGS), "i")
benchmark_test_enabled(name) =
    isnothing(BENCHMARK_TEST_PATTERN) ||
    occursin(BENCHMARK_TEST_PATTERN, name)

if benchmark_test_enabled("full-performance project bootstrap smoke")
    @testset "full-performance project bootstrap smoke" begin
        include(
            joinpath(
                @__DIR__,
                "..",
                "prepare_full_performance_project.jl",
            ),
        )
        mktempdir() do directory
            project_path = joinpath(directory, "Project.toml")
            cp(
                joinpath(@__DIR__, "..", "Project.toml"),
                project_path,
            )
            prepare_full_performance_project!(project_path)
            project = TOML.parsefile(project_path)
            @test !haskey(project, "sources")
            @test haskey(project["deps"], "PlantSimEngine")
            @test haskey(project["deps"], "XPalm")
            @test haskey(project["deps"], "PlantBiophysics")
        end
        mktempdir() do directory
            project_path = joinpath(directory, "Project.toml")
            cp(
                joinpath(@__DIR__, "..", "Project.toml"),
                project_path,
            )
            prepare_plantbiophysics_performance_project!(project_path)
            project = TOML.parsefile(project_path)
            @test !haskey(project, "sources")
            @test haskey(project["deps"], "PlantSimEngine")
            @test haskey(project["deps"], "PlantBiophysics")
            @test !haskey(project["deps"], "XPalm")
        end

        release_root = joinpath(@__DIR__, "..", "release_baselines")
        release_projects = Dict(
            :plantbiophysics => TOML.parsefile(
                joinpath(release_root, "plantbiophysics", "Project.toml"),
            ),
            :xpalm => TOML.parsefile(
                joinpath(release_root, "xpalm", "Project.toml"),
            ),
        )
        @test release_projects[:plantbiophysics]["sources"][
            "PlantBiophysics"
        ]["rev"] == "9f39af4ffd48bab234e5d80b89cd52c67b9f3f82"
        @test release_projects[:plantbiophysics]["sources"][
            "PlantSimEngine"
        ]["rev"] == "503af98c3709a0b1207407e3741b7cb09ebfbcf7"
        @test release_projects[:xpalm]["sources"]["XPalm"]["rev"] ==
              "a0dbf2e8d6fa9e21f8e8ced3220da184b3ee3f4c"
        @test release_projects[:xpalm]["sources"][
            "PlantSimEngine"
        ]["rev"] == "503af98c3709a0b1207407e3741b7cb09ebfbcf7"
        for downstream in keys(release_projects)
            runner = joinpath(release_root, String(downstream), "run.jl")
            @test Meta.parseall(read(runner, String)) isa Expr
        end
    end
end

if benchmark_test_enabled("PlantSimEngine benchmark API smoke")
    @testset "PlantSimEngine benchmark API smoke" begin
        include(joinpath(@__DIR__, "..", "test-PSE-benchmark.jl"))
        model, requests, _ = setup_heavier_model_benchmark()
        simulation = benchmark_heavier_scene(model, requests, 1)
        @test current_step(simulation) == 1
        @test !isempty(collect_outputs(simulation; sink=nothing))
    end
end

if benchmark_test_enabled("multirate benchmark API smoke")
    @testset "multirate benchmark API smoke" begin
        include(joinpath(@__DIR__, "..", "test-multirate-buffer-benchmark.jl"))
        model, requests, nsteps =
            setup_multirate_buffer_benchmark(; ndays=1, nleaves=4)
        simulation =
            benchmark_multirate_output_request_run(model, requests, nsteps)
        @test current_step(simulation) == nsteps
        @test !isempty(collect_outputs(simulation; sink=nothing))
        no_output_model, _, no_output_steps =
            setup_multirate_buffer_benchmark(; ndays=1, nleaves=4)
        no_output_simulation =
            benchmark_multirate_no_output_run(
                no_output_model,
                no_output_steps,
            )
        @test current_step(no_output_simulation) == no_output_steps
        retention =
            PlantSimEngine.Diagnostics.explain_output_retention(
                no_output_simulation,
            )
        @test all(
            row.reasons == (:temporal_dependency,)
            for row in retention
        )
        @test maximum(
            length,
            values(outputs(no_output_simulation)),
        ) <= 25
    end
end

if benchmark_test_enabled("immutable scenario benchmark API smoke")
    @testset "immutable scenario benchmark API smoke" begin
        include(
            joinpath(
                @__DIR__,
                "..",
                "test-immutable-scenario-benchmark.jl",
            ),
        )
        for output_policy in (:none, :requests, :all)
            simulation = setup_immutable_scenario_benchmark(;
                nleaves=4,
                output_policy=output_policy,
            )
            benchmark_immutable_scenario_steps(simulation, 48)
            @test current_step(simulation) == 49
            @test only(model_objects(simulation.model; scale=:Plant)).status.total ==
                  4 * 48
            performance =
                PlantSimEngine.Advanced.runtime_performance(simulation)
            @test performance.counts[:steps_executed] == 49
            @test performance.counts[:application_groups_considered] == 98
            @test performance.counts[:application_groups_visited] == 52
            @test performance.counts[:execution_batches_visited] == 52
            @test performance.counts[:execution_targets_visited] == 199
            @test !haskey(
                performance.counts,
                :output_request_target_refreshes,
            )
            if output_policy === :requests
                @test !haskey(
                    performance.counts,
                    :output_request_selector_resolutions,
                )
                @test !isempty(collect_outputs(simulation; sink=nothing))

                register_object!(
                    simulation.model,
                    Object(:leaf_5; scale=:Leaf, kind=:leaf, parent=:plant),
                )
                continue!(simulation)
                lifecycle_performance =
                    PlantSimEngine.Advanced.runtime_performance(simulation)
                @test lifecycle_performance.counts[
                    :output_request_target_refreshes
                ] == 1
                @test lifecycle_performance.counts[
                    :output_request_incremental_object_checks
                ] == 1
                @test !haskey(
                    lifecycle_performance.counts,
                    :output_request_selector_resolutions,
                )
                @test count(
                    row -> row.object_id == :leaf_5,
                    collect_outputs(
                        simulation,
                        :leaf_signal;
                        sink=nothing,
                    ),
                ) == 1
            else
                @test !haskey(
                    performance.counts,
                    :output_request_selector_resolutions,
                )
            end
        end
    end
end

if benchmark_test_enabled("lifecycle benchmark API smoke")
    @testset "lifecycle benchmark API smoke" begin
        isdefined(@__MODULE__, :BenchmarkCallSourceModel) ||
            include(
                joinpath(
                    @__DIR__,
                    "..",
                    "test-hard-call-path-benchmark.jl",
                ),
            )
        for (nobjects, usage) in (
            (8, :zero),
            (64, :zero),
            (16, :dense),
        )
            simulation, new_index =
                setup_lifecycle_hard_call_benchmark(;
                    nobjects=nobjects,
                    usage=usage,
                )
            benchmark_lifecycle_event(simulation, new_index)
            new_id = Symbol(:leaf_, new_index)
            new_object = only(
                object for object in model_objects(
                    simulation.model;
                    scale=:Leaf,
                )
                if object.id == ObjectId(new_id)
            )
            @test current_step(simulation) == 2
            @test new_object.status.work == 1
            @test new_object.status.signal == 1
            if usage == :dense
                @test new_object.status.called_signal == 1
            end
            performance =
                PlantSimEngine.Advanced.runtime_performance(simulation)
            @test performance.counts[
                :execution_target_rebuild_new
            ] <= 3
        end
    end
end

if benchmark_test_enabled("hard-call path benchmark API smoke")
    @testset "hard-call path benchmark API smoke" begin
        include(joinpath(@__DIR__, "..", "test-hard-call-path-benchmark.jl"))
        expected_call_targets = Dict(
            :zero => 0,
            :sparse => 1,
            :dense => 16,
        )
        for usage in (:zero, :sparse, :dense)
            model, steps = setup_hard_call_path_benchmark(;
                nobjects=16,
                usage=usage,
                steps=2,
            )
            summary = hard_call_path_summary(model)
            @test summary.call_capable_targets ==
                  expected_call_targets[usage]
            @test summary.unrelated_no_call_targets == 16
            simulation = benchmark_hard_call_path(model, steps)
            @test current_step(simulation) == steps
            @test all(
                object.status.work == steps
                for object in model_objects(model; scale=:Leaf)
            )
        end
        for (kind, repeats, target_count, expected_signal) in (
            (:singular, 1, 1, 2),
            (:repeated, 8, 1, 16),
            (:nested, 1, 1, 2),
            (:many, 1, 8, 2),
            (:published, 1, 1, 2),
        )
            model, steps = setup_compiled_hard_call_benchmark(;
                kind=kind,
                repeats=repeats,
                target_count=target_count,
                steps=2,
            )
            simulation = benchmark_compiled_hard_call(model, steps)
            @test current_step(simulation) == steps
            leaves = model_objects(model; scale=:Leaf)
            @test length(leaves) == target_count
            @test all(
                leaf.status.signal == expected_signal for leaf in leaves
            )
        end
        heterogeneous_model, heterogeneous_steps =
            setup_compiled_hard_call_benchmark(;
                kind=:heterogeneous,
                steps=2,
            )
        heterogeneous_simulation = benchmark_compiled_hard_call(
            heterogeneous_model,
            heterogeneous_steps,
        )
        heterogeneous_leaves = sort!(
            model_objects(heterogeneous_model; scale=:Leaf);
            by=object -> string(object.id.value),
        )
        @test current_step(heterogeneous_simulation) == 2
        @test getproperty.(getproperty.(heterogeneous_leaves, :status), :signal) ==
              [2, 4]
        sampled_model, sampled_steps = setup_compiled_hard_call_benchmark(;
            kind=:sampled_environment,
            steps=2,
        )
        sampled_simulation = benchmark_compiled_hard_call(
            sampled_model,
            sampled_steps,
        )
        sampled_leaf = only(model_objects(sampled_model; scale=:Leaf))
        @test current_step(sampled_simulation) == 2
        @test sampled_leaf.status.temperature_seen == 30.0
        for (kind, repeats, target_count) in (
            (:singular, 1, 1),
            (:repeated, 8, 1),
            (:nested, 1, 1),
            (:many, 1, 8),
            (:heterogeneous, 1, 2),
        )
            setup_compiled_hard_call_step(;
                kind=kind,
                repeats=repeats,
                target_count=target_count,
            )
            context = BENCHMARK_BULK_CALL_CONTEXT[]
            @test compiled_hard_call_invocation_allocations(
                context;
                repeats=repeats,
                publish=false,
            ) == 0
        end
        setup_compiled_hard_call_step(; kind=:published)
        published_context = BENCHMARK_BULK_CALL_CONTEXT[]
        @test compiled_hard_call_invocation_allocations(
            published_context;
            publish=true,
        ) <= 256
        setup_compiled_hard_call_step(; kind=:sampled_environment)
        sampled_context = BENCHMARK_BULK_CALL_CONTEXT[]
        @test sampled_hard_call_invocation_allocations(
            sampled_context,
            (T=31.0,),
        ) == 0
    end
end

if benchmark_test_enabled("internal-only benchmark suite assembly smoke")
    @testset "internal-only benchmark suite assembly smoke" begin
        benchmark_module = Module(:InternalOnlyBenchmarkSuite)
        Core.eval(
            benchmark_module,
            :(include(path) = Base.include(@__MODULE__, path)),
        )
        Core.eval(benchmark_module, :(const Object = Nothing))
        include_error = try
            withenv(
                "GITHUB_ACTIONS" => "true",
                "PSE_BENCHMARK_INCLUDE_DOWNSTREAM" => nothing,
                "PSE_BENCHMARK_FORCE_LEGACY_BASELINE" => nothing,
            ) do
                Base.include(
                    benchmark_module,
                    joinpath(@__DIR__, "..", "benchmarks.jl"),
                )
            end
            nothing
        catch error
            sprint(showerror, error, catch_backtrace())
        end
        @test isnothing(include_error)
        if isnothing(include_error)
            suite = getfield(
                benchmark_module,
                :SUITE,
            )[getfield(benchmark_module, :suite_name)]
            @test haskey(suite, "PSE_status_read_write")
            @test haskey(suite, "PSE")
            @test haskey(suite, "PSE_hard_calls_zero")
            @test haskey(suite, "PSE_lifecycle_large")
            @test haskey(suite, "PSE_immutable_scenario_none")
            @test haskey(suite, "PSE_immutable_scenario_requests")
            @test haskey(suite, "PSE_immutable_scenario_all")
            @test !haskey(suite, "PBP")
            @test !haskey(suite, "PBP_batch_run")
            @test !haskey(suite, "XPalm_run_100")
            @test !haskey(suite, "XPalm_all_outputs_100")
        end
    end
end

if benchmark_test_enabled("legacy benchmark suite assembly smoke")
    @testset "legacy benchmark suite assembly smoke" begin
        benchmark_module = Module(:LegacyBenchmarkSuite)
        Core.eval(
            benchmark_module,
            :(include(path) = Base.include(@__MODULE__, path)),
        )
        include_error = try
            withenv(
                "GITHUB_ACTIONS" => "true",
                "PSE_BENCHMARK_INCLUDE_DOWNSTREAM" => nothing,
                "PSE_BENCHMARK_FORCE_LEGACY_BASELINE" => "true",
            ) do
                Base.include(
                    benchmark_module,
                    joinpath(@__DIR__, "..", "benchmarks.jl"),
                )
            end
            nothing
        catch error
            sprint(showerror, error, catch_backtrace())
        end
        @test isnothing(include_error)
        if isnothing(include_error)
            suite = getfield(
                benchmark_module,
                :SUITE,
            )[getfield(benchmark_module, :suite_name)]
            @test haskey(suite, "PSE_status_read_write")
            @test !haskey(suite, "PSE")
            @test !haskey(suite, "PSE_multirate_no_output_run")
            @test !haskey(suite, "PSE_hard_calls_zero")
            @test !haskey(suite, "PBP")
            @test !haskey(suite, "XPalm_run_100")
        end
    end
end

if benchmark_test_enabled("PlantBiophysics benchmark API smoke")
    @testset "PlantBiophysics benchmark API smoke" begin
        include(joinpath(@__DIR__, "..", "test-plantbiophysics.jl"))
        scenes = setup_benchmark_plantbiophysics_batch(; n=2)
        @test isnothing(benchmark_plantbiophysics_batch(scenes))
        model, nsteps = setup_plantbiophysics_multistep(; nsteps=2)
        simulation = benchmark_plantbiophysics_multistep(
            model,
            nsteps;
            outputs=:none,
        )
        @test current_step(simulation) == nsteps
        records = run_plantbiophysics_performance_profile(;
            nsteps=2,
            fanout_scenes=2,
            samples=2,
        )
        @test Set(record.stage for record in records) ==
              Set([
            "steady_state_no_retention",
            "steady_state_retain_all",
            "construction_only",
            "one_step_fanout",
        ])
        steady_records = filter(
            record -> record.scope == "one_setup_many_timesteps",
            records,
        )
        @test length(steady_records) == 2
        @test all(record.nscenes == 1 for record in steady_records)
        @test all(record.nsteps_per_scene == 2 for record in steady_records)
        @test all(record.total_model_steps == 2 for record in steady_records)
        @test all(record.samples == 2 for record in records)
        @test all(record.minimum_time_ns > 0 for record in records)
    end
end

if !isnothing(BENCHMARK_TEST_PATTERN) &&
   benchmark_test_enabled("PlantBiophysics benchmark performance")
    @testset "PlantBiophysics benchmark performance" begin
        isdefined(@__MODULE__, :run_plantbiophysics_performance_profile) ||
            include(joinpath(@__DIR__, "..", "test-plantbiophysics.jl"))
        output_path = get(
            ENV,
            "PSE_PLANTBIOPHYSICS_BENCHMARK_OUTPUT",
            joinpath(
                @__DIR__,
                "..",
                "results",
                "plantbiophysics-full-latest.csv",
            ),
        )
        samples = parse(
            Int,
            get(ENV, "PSE_PLANTBIOPHYSICS_BENCHMARK_SAMPLES", "10"),
        )
        nsteps = parse(
            Int,
            get(ENV, "PSE_PLANTBIOPHYSICS_BENCHMARK_STEPS", "8760"),
        )
        fanout_scenes = parse(
            Int,
            get(ENV, "PSE_PLANTBIOPHYSICS_FANOUT_SCENES", "100"),
        )
        records = write_plantbiophysics_performance_profile(
            output_path;
            nsteps=nsteps,
            fanout_scenes=fanout_scenes,
            samples=samples,
        )
        @test isfile(output_path)
        @test length(records) == 4
        @test only(
            record.nsteps_per_scene for record in records
            if record.stage == "steady_state_no_retention"
        ) == nsteps
        @test only(
            record.nscenes for record in records
            if record.stage == "one_step_fanout"
        ) == fanout_scenes
        @test all(record.samples == samples for record in records)
    end
end

if benchmark_test_enabled("XPalm benchmark API smoke")
    @testset "XPalm benchmark API smoke" begin
        include(joinpath(@__DIR__, "..", "test-xpalm.jl"))
        model, requests, _ = xpalm_default_param_create()
        simulation = PlantSimEngine.run!(model; steps=1, outputs=requests)
        @test current_step(simulation) == 1
        @test !isempty(xpalm_default_param_collect_outputs(simulation))
    end
end

if benchmark_test_enabled("XPalm staged performance profile smoke")
    @testset "XPalm staged performance profile smoke" begin
        include(joinpath(@__DIR__, "..", "performance_regression.jl"))
        metadata = _performance_metadata(; warmup_policy="metadata smoke")
        @test length(metadata.manifest_hash) == 64
        @test length(metadata.fixture_hash) == 64
        @test !isempty(metadata.hostname)
        @test !isempty(metadata.plantgeom_revision)
        result = run_xpalm_performance_profile(; profile=:smoke)
        @test result.no_output_state == result.reference_state
        @test result.small_state == result.reference_state
        @test result.all_output_state == result.reference_state
        @test result.reference_state.current_step == PERFORMANCE_SMOKE_STEPS
        @test any(
            row ->
                row.stage == "simulation_reference_outputs" &&
                    row.metric == "steps_executed" &&
                    row.value == PERFORMANCE_SMOKE_STEPS,
            result.records,
        )
        @test any(
            row ->
                row.stage == "initial_scene_compilation" &&
                    row.metric == "median_time",
            result.records,
        )
        @test any(
            row ->
                row.stage == "clean_steady_state_step" &&
                    row.metric == "median_time",
            result.records,
        )
        @test any(
            row ->
                row.stage == "simulation_small_outputs" &&
                    row.metric == "median_time",
            result.records,
        )
        @test any(
            row ->
                row.stage == "simulation_all_outputs" &&
                    row.metric == "median_time",
            result.records,
        )
        @test any(
            row ->
                row.stage == "collect_reference_outputs" &&
                    row.metric == "wall_time",
            result.records,
        )
        @test any(
            row ->
                row.stage == "simulation_reference_outputs" &&
                    row.metric == "median_time",
            result.records,
        )
        @test any(
            row ->
                row.stage == "simulation_reference_outputs" &&
                    row.metric == "minimum_allocations",
            result.records,
        )
        @test only(
            row.value for row in result.records
            if row.stage == "simulation_reference_outputs" &&
               row.metric == "samples"
        ) == PERFORMANCE_STATISTICAL_SAMPLES
        trial = BenchmarkTools.@benchmark 1 + 1 samples = 2 evals = 1
        group = BenchmarkTools.BenchmarkGroup()
        group["tiny"] = trial
        summary = _benchmark_summary_records(group, metadata)
        @test length(summary) == 1
        @test only(summary).benchmark == "tiny"
        @test only(summary).samples == 2
        @test only(summary).minimum_time_ns <= only(summary).median_time_ns
        @test only(summary).median_allocations == 0
    end
end

if !isnothing(BENCHMARK_TEST_PATTERN) &&
   benchmark_test_enabled("benchmark suite assembly smoke")
    @testset "benchmark suite assembly smoke" begin
        include(joinpath(@__DIR__, "..", "benchmarks.jl"))
        suite = SUITE[suite_name]
        @test haskey(suite, "PSE_hard_calls_zero")
        @test haskey(suite, "PSE_hard_calls_sparse")
        @test haskey(suite, "PSE_hard_calls_dense")
        @test haskey(suite, "PSE_compiled_hard_call_singular")
        @test haskey(suite, "PSE_compiled_hard_call_repeated")
        @test haskey(suite, "PSE_compiled_hard_call_nested")
        @test haskey(suite, "PSE_compiled_hard_call_many")
        @test haskey(suite, "PSE_compiled_hard_call_heterogeneous")
        @test haskey(suite, "PSE_compiled_hard_call_sampled_environment")
        @test haskey(suite, "PSE_compiled_hard_call_published")
        @test haskey(suite, "PSE_lifecycle_small")
        @test haskey(suite, "PSE_lifecycle_large")
        @test haskey(
            suite,
            "PSE_lifecycle_immediate_hard_call",
        )
        @test haskey(suite, "PSE_multirate_no_output_run")
        @test haskey(suite, "PBP_multistep_no_outputs")
        @test haskey(suite, "PBP_multistep_all_outputs")
        @test haskey(suite, "PBP_construction")
        @test haskey(suite, "PBP_one_step_fanout")
        @test haskey(suite, "XPalm_small_outputs_100")
        @test haskey(suite, "XPalm_all_outputs_100")
    end
end

if !isnothing(BENCHMARK_TEST_PATTERN) &&
   benchmark_test_enabled("XPalm staged performance profile short")
    @testset "XPalm staged performance profile short" begin
        include(joinpath(@__DIR__, "..", "performance_regression.jl"))
        output_path = joinpath(
            @__DIR__,
            "..",
            "results",
            "xpalm-short-latest.csv",
        )
        result = write_xpalm_performance_profile(output_path; profile=:short)
        @test result.no_output_state == result.reference_state
        @test result.reference_state.current_step == PERFORMANCE_SHORT_STEPS
        @test isfile(output_path)
        @test any(
            row ->
                row.stage == "simulation_no_outputs" &&
                    row.metric == "execution_targets_visited",
            result.records,
        )
    end
end

if !isnothing(BENCHMARK_TEST_PATTERN) &&
   benchmark_test_enabled("XPalm staged performance profile medium")
    @testset "XPalm staged performance profile medium" begin
        include(joinpath(@__DIR__, "..", "performance_regression.jl"))
        output_path = joinpath(
            @__DIR__,
            "..",
            "results",
            "xpalm-medium-latest.csv",
        )
        result = write_xpalm_performance_profile(output_path; profile=:medium)
        @test result.no_output_state == result.reference_state
        @test result.reference_state.current_step == PERFORMANCE_MEDIUM_STEPS
        @test isfile(output_path)
        @test any(
            row ->
                row.stage == "simulation_no_outputs" &&
                    row.metric == "output_retention_reuses",
            result.records,
        )
    end
end

if !isnothing(BENCHMARK_TEST_PATTERN) &&
   benchmark_test_enabled("XPalm staged performance profile full")
    @testset "XPalm staged performance profile full" begin
        include(joinpath(@__DIR__, "..", "performance_regression.jl"))
        output_path = joinpath(
            @__DIR__,
            "..",
            "results",
            "xpalm-full-latest.csv",
        )
        result = write_xpalm_performance_profile(output_path; profile=:full)
        @test result.no_output_state == result.reference_state
        @test xpalm_reference_state_matches(result.reference_state)
        @test isfile(output_path)
        @test any(
            row ->
                row.stage == "historical_end_to_end_reference" &&
                    row.metric == "wall_time",
            result.records,
        )
    end
end

if !isnothing(BENCHMARK_TEST_PATTERN) &&
   benchmark_test_enabled("XPalm full no-output performance")
    @testset "XPalm full no-output performance" begin
        include(joinpath(@__DIR__, "..", "performance_regression.jl"))
        _warmup_xpalm_performance!(PERFORMANCE_FULL_STEPS)
        metadata = _performance_metadata(;
            warmup_policy="unmeasured full-profile standard warmup",
        )
        records = NamedTuple[]
        output_path = joinpath(
            @__DIR__,
            "..",
            "results",
            "xpalm-full-no-output-latest.csv",
        )
        model, nsteps = _measure_performance_stage!(
            records,
            metadata,
            :full,
            :scene_construction_no_outputs,
            output_path,
        ) do
            xpalm_reference_model_create(; nsteps=PERFORMANCE_FULL_STEPS)
        end
        simulation = _measure_performance_stage!(
            records,
            metadata,
            :full,
            :simulation_no_outputs,
            output_path,
        ) do
            xpalm_reference_param_run(
                model,
                OutputRequest[],
                nsteps;
                outputs=:none,
            )
        end
        final_state = xpalm_reference_final_state(simulation)
        _record_xpalm_state!(
            records,
            metadata,
            :full,
            :final_state_no_outputs,
            final_state,
        )
        _checkpoint_performance_records(output_path, records)
        @test final_state.current_step == PERFORMANCE_FULL_STEPS
        @test final_state.phytomer_count == 344
        @test isfile(output_path)
    end
end

if !isnothing(BENCHMARK_TEST_PATTERN) &&
   benchmark_test_enabled("XPalm full warmed no-output performance")
    @testset "XPalm full warmed no-output performance" begin
        include(joinpath(@__DIR__, "..", "performance_regression.jl"))
        warmup_model, warmup_steps =
            xpalm_reference_model_create(; nsteps=PERFORMANCE_FULL_STEPS)
        xpalm_reference_param_run(
            warmup_model,
            OutputRequest[],
            warmup_steps;
            outputs=:none,
        )
        model, nsteps =
            xpalm_reference_model_create(; nsteps=PERFORMANCE_FULL_STEPS)
        metadata = _performance_metadata(;
            warmup_policy="unmeasured complete 4,160-day lifecycle run",
        )
        records = NamedTuple[]
        output_path = joinpath(
            @__DIR__,
            "..",
            "results",
            "xpalm-full-warmed-no-output-latest.csv",
        )
        simulation = _measure_performance_stage!(
            records,
            metadata,
            :full,
            :simulation_warmed_no_outputs,
            output_path,
        ) do
            xpalm_reference_param_run(
                model,
                OutputRequest[],
                nsteps;
                outputs=:none,
            )
        end
        final_state = xpalm_reference_final_state(simulation)
        _record_xpalm_state!(
            records,
            metadata,
            :full,
            :final_state_warmed_no_outputs,
            final_state,
        )
        _checkpoint_performance_records(output_path, records)
        wall_time = only(
            row.value for row in records
            if row.stage == "simulation_warmed_no_outputs" &&
               row.metric == "wall_time"
        )
        @test final_state.current_step == PERFORMANCE_FULL_STEPS
        @test final_state.phytomer_count == 344
        @test xpalm_reference_state_matches(final_state)
        @test wall_time <= 20.0
        @test isfile(output_path)
    end
end

if !isnothing(BENCHMARK_TEST_PATTERN) &&
   benchmark_test_enabled("XPalm full steady tail performance")
    @testset "XPalm full steady tail performance" begin
        include(joinpath(@__DIR__, "..", "performance_regression.jl"))
        _warmup_xpalm_performance!(PERFORMANCE_SHORT_STEPS)
        model, nsteps =
            xpalm_reference_model_create(; nsteps=PERFORMANCE_FULL_STEPS)
        tail_steps = 660
        simulation = xpalm_reference_param_run(
            model,
            OutputRequest[],
            nsteps - tail_steps;
            outputs=:none,
        )
        GC.gc()
        measurement = @timed PlantSimEngine.continue!(
            simulation;
            steps=tail_steps,
        )
        output_path = joinpath(
            @__DIR__,
            "..",
            "results",
            "xpalm-full-steady-tail-latest.csv",
        )
        CSV.write(
            output_path,
            DataFrame(
                metric=["wall_time", "allocated", "gc_time"],
                value=[
                    measurement.time,
                    measurement.bytes,
                    measurement.gctime,
                ],
            ),
        )
        @test current_step(simulation) == PERFORMANCE_FULL_STEPS
        @test isfile(output_path)
    end
end

if !isnothing(BENCHMARK_TEST_PATTERN) &&
   benchmark_test_enabled("XPalm allocation profile short")
    @testset "XPalm allocation profile short" begin
        include(joinpath(@__DIR__, "..", "performance_regression.jl"))
        _warmup_xpalm_performance!(PERFORMANCE_SHORT_STEPS)
        model, nsteps =
            xpalm_reference_model_create(; nsteps=PERFORMANCE_SHORT_STEPS)
        Profile.Allocs.clear()
        simulation = Profile.Allocs.@profile sample_rate = 0.01 xpalm_reference_param_run(
            model,
            OutputRequest[],
            nsteps;
            outputs=:none,
        )
        allocation_results = Profile.Allocs.fetch()
        pse_root = dirname(dirname(@__DIR__))
        xpalm_root = dirname(dirname(pathof(XPalm)))
        totals = Dict{
            Tuple{String,String,Int,String,String},
            Tuple{Int,Int},
        }()
        for allocation in allocation_results.allocs
            frame_index = findfirst(allocation.stacktrace) do frame
                file = string(frame.file)
                occursin(pse_root, file) || occursin(xpalm_root, file)
            end
            isnothing(frame_index) && continue
            frame = allocation.stacktrace[frame_index]
            file = string(frame.file)
            source = occursin(pse_root, file) ? "PlantSimEngine" : "XPalm"
            key = (
                source,
                file,
                frame.line,
                string(frame.func),
                string(allocation.type),
            )
            count, bytes = get(totals, key, (0, 0))
            totals[key] = (count + 1, bytes + allocation.size)
        end
        rows = [
            (
                source=first(key),
                file=key[2],
                line=key[3],
                function_name=key[4],
                allocation_type=key[5],
                sampled_allocations=first(value),
                sampled_bytes=last(value),
                sample_rate=0.01,
            )
            for (key, value) in totals
        ]
        sort!(rows; by=row -> row.sampled_bytes, rev=true)
        output_path = joinpath(
            @__DIR__,
            "..",
            "results",
            "xpalm-allocations-short-latest.csv",
        )
        CSV.write(output_path, DataFrame(rows))
        @test current_step(simulation) == PERFORMANCE_SHORT_STEPS
        @test !isempty(rows)
        @test isfile(output_path)
    end
end

if !isnothing(BENCHMARK_TEST_PATTERN) &&
   benchmark_test_enabled("XPalm CPU profile medium")
    @testset "XPalm CPU profile medium" begin
        include(joinpath(@__DIR__, "..", "performance_regression.jl"))
        _warmup_xpalm_performance!(PERFORMANCE_MEDIUM_STEPS)
        model, nsteps =
            xpalm_reference_model_create(; nsteps=PERFORMANCE_MEDIUM_STEPS)
        Profile.clear()
        simulation = Profile.@profile xpalm_reference_param_run(
            model,
            OutputRequest[],
            nsteps;
            outputs=:none,
        )
        output_path = joinpath(
            @__DIR__,
            "..",
            "results",
            "xpalm-cpu-medium-latest.txt",
        )
        open(output_path, "w") do io
            Profile.print(
                io;
                format=:flat,
                sortedby=:count,
                C=false,
                combine=true,
            )
        end
        @test current_step(simulation) == PERFORMANCE_MEDIUM_STEPS
        @test isfile(output_path)
    end
end

if !isnothing(BENCHMARK_TEST_PATTERN) &&
   benchmark_test_enabled("XPalm CPU profile full")
    @testset "XPalm CPU profile full" begin
        include(joinpath(@__DIR__, "..", "performance_regression.jl"))
        _warmup_xpalm_performance!(PERFORMANCE_FULL_STEPS)
        model, nsteps =
            xpalm_reference_model_create(; nsteps=PERFORMANCE_FULL_STEPS)
        profiled_steps = 660
        simulation = xpalm_reference_param_run(
            model,
            OutputRequest[],
            nsteps - profiled_steps;
            outputs=:none,
        )
        Profile.clear()
        Profile.@profile PlantSimEngine.continue!(
            simulation;
            steps=profiled_steps,
        )
        output_path = joinpath(
            @__DIR__,
            "..",
            "results",
            "xpalm-cpu-full-latest.txt",
        )
        open(output_path, "w") do io
            Profile.print(
                io;
                format=:flat,
                sortedby=:count,
                C=false,
                combine=true,
            )
        end
        @test current_step(simulation) == PERFORMANCE_FULL_STEPS
        @test isfile(output_path)
    end
end
