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
    end
end

if benchmark_test_enabled("internal-only benchmark suite assembly smoke")
    @testset "internal-only benchmark suite assembly smoke" begin
        benchmark_module = Module(:InternalOnlyBenchmarkSuite)
        Core.eval(
            benchmark_module,
            :(include(path) = Base.include(@__MODULE__, path)),
        )
        include_error = try
            withenv(
                "GITHUB_ACTIONS" => "true",
                "PSE_BENCHMARK_INCLUDE_DOWNSTREAM" => nothing,
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
            @test haskey(suite, "PSE")
            @test haskey(suite, "PSE_hard_calls_zero")
            @test haskey(suite, "PSE_lifecycle_large")
            @test !haskey(suite, "PBP")
            @test !haskey(suite, "PBP_batch_run")
            @test !haskey(suite, "XPalm_run_100")
            @test !haskey(suite, "XPalm_all_outputs_100")
        end
    end
end

if benchmark_test_enabled("PlantBiophysics benchmark API smoke")
    @testset "PlantBiophysics benchmark API smoke" begin
        include(joinpath(@__DIR__, "..", "test-plantbiophysics.jl"))
        scenes = setup_benchmark_plantbiophysics_batch(; n=2)
        @test isnothing(benchmark_plantbiophysics_batch(scenes))
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
        @test haskey(suite, "PSE_lifecycle_small")
        @test haskey(suite, "PSE_lifecycle_large")
        @test haskey(
            suite,
            "PSE_lifecycle_immediate_hard_call",
        )
        @test haskey(suite, "PSE_multirate_no_output_run")
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
