using BenchmarkTools
using CSV
using DataFrames
using Dates
using PlantSimEngine
using SHA
using Sockets
using Statistics
using XPalm

isdefined(@__MODULE__, :xpalm_reference_param_create) ||
    include(joinpath(@__DIR__, "test-xpalm.jl"))

const PERFORMANCE_SMOKE_STEPS = 2
const PERFORMANCE_SHORT_STEPS = 100
const PERFORMANCE_MEDIUM_STEPS = 1000
const PERFORMANCE_FULL_STEPS = 4160
const PERFORMANCE_STATISTICAL_SAMPLES = 3

function _performance_git_revision(path)
    try
        return readchomp(`git -C $path rev-parse HEAD`)
    catch
        return "unknown"
    end
end

function _performance_path_hash(path)
    if isfile(path)
        return bytes2hex(SHA.sha256(read(path)))
    elseif isdir(path)
        entries = String[]
        for (root, directories, files) in walkdir(path)
            sort!(directories)
            for file in sort!(files)
                file_path = joinpath(root, file)
                relative_path = relpath(file_path, path)
                push!(
                    entries,
                    string(
                        relative_path,
                        '\0',
                        bytes2hex(SHA.sha256(read(file_path))),
                    ),
                )
            end
        end
        return bytes2hex(SHA.sha256(codeunits(join(entries, '\n'))))
    end
    return "missing"
end

function _performance_fixture_hash(xpalm_root)
    paths = (
        joinpath(xpalm_root, "0-data", "meteo.csv"),
        joinpath(
            xpalm_root,
            "test",
            "references",
            "regression",
            "v0.6.1",
        ),
    )
    entries = String[
        string(relpath(path, xpalm_root), '\0', _performance_path_hash(path))
        for path in paths
    ]
    return bytes2hex(SHA.sha256(codeunits(join(entries, '\n'))))
end

function _performance_metadata(; warmup_policy)
    pse_root = dirname(@__DIR__)
    xpalm_root = dirname(dirname(pathof(XPalm)))
    plantbiophysics_source = Base.find_package("PlantBiophysics")
    plantbiophysics_root = isnothing(plantbiophysics_source) ?
                           nothing :
                           dirname(dirname(plantbiophysics_source))
    plantgeom_source = Base.find_package("PlantGeom")
    plantgeom_root = isnothing(plantgeom_source) ?
                     nothing :
                     dirname(dirname(plantgeom_source))
    manifest_path = joinpath(pse_root, "benchmark", "Manifest.toml")
    return (
        recorded_at=Dates.format(Dates.now(), dateformat"yyyy-mm-ddTHH:MM:SS.sss"),
        julia_version=string(VERSION),
        hostname=Sockets.gethostname(),
        machine=Sys.MACHINE,
        cpu=Sys.CPU_NAME,
        memory_bytes=Sys.total_memory(),
        threads=Threads.nthreads(),
        plantsimengine_revision=_performance_git_revision(pse_root),
        plantbiophysics_revision=isnothing(plantbiophysics_root) ?
                                  "unavailable" :
                                  _performance_git_revision(
            plantbiophysics_root,
        ),
        plantgeom_revision=isnothing(plantgeom_root) ?
                           "unavailable" :
                           _performance_git_revision(plantgeom_root),
        xpalm_revision=_performance_git_revision(xpalm_root),
        manifest_hash=_performance_path_hash(manifest_path),
        fixture_hash=_performance_fixture_hash(xpalm_root),
        warmup_policy=warmup_policy,
    )
end

function _benchmark_summary_records(
    results,
    metadata;
    benchmark_path=String[],
)
    records = NamedTuple[]
    for (name, result) in pairs(results)
        path = [benchmark_path; string(name)]
        if result isa BenchmarkTools.Trial
            median_estimate = BenchmarkTools.median(result)
            minimum_estimate = BenchmarkTools.minimum(result)
            push!(
                records,
                merge(
                    metadata,
                    (
                        benchmark=join(path, "/"),
                        samples=length(result),
                        median_time_ns=median_estimate.time,
                        minimum_time_ns=minimum_estimate.time,
                        median_memory_bytes=median_estimate.memory,
                        minimum_memory_bytes=minimum_estimate.memory,
                        median_allocations=median_estimate.allocs,
                        minimum_allocations=minimum_estimate.allocs,
                    ),
                ),
            )
        else
            append!(
                records,
                _benchmark_summary_records(
                    result,
                    metadata;
                    benchmark_path=path,
                ),
            )
        end
    end
    return records
end

function write_benchmark_summary(path, results, metadata)
    records = _benchmark_summary_records(results, metadata)
    mkpath(dirname(path))
    CSV.write(path, DataFrame(records))
    return records
end

function _performance_record!(
    records,
    metadata,
    profile,
    stage,
    metric,
    value,
    unit,
)
    push!(
        records,
        merge(
            metadata,
            (
                profile=String(profile),
                stage=String(stage),
                metric=String(metric),
                value=Float64(value),
                unit=String(unit),
            ),
        ),
    )
    return records
end

function _checkpoint_performance_records(path, records)
    isnothing(path) && return records
    mkpath(dirname(path))
    CSV.write(path, DataFrame(records))
    return records
end

function _performance_allocation_count(measurement)
    stats = measurement.gcstats
    return sum((
        Int(getproperty(stats, name))
        for name in (:malloc, :realloc, :poolalloc, :bigalloc)
        if hasproperty(stats, name)
    ); init=0)
end

function _timed_performance_operation(operation)
    GC.gc()
    return @timed operation()
end

function _measure_performance_stage!(
    operation,
    records,
    metadata,
    profile,
    stage,
    checkpoint_path=nothing,
    ;
    samples::Int=1,
    sample_factory=nothing,
)
    samples >= 1 || error("Performance stage samples must be positive.")
    started_at = time_ns()
    measurement = try
        _timed_performance_operation(operation)
    catch
        _performance_record!(
            records,
            metadata,
            profile,
            stage,
            :failed,
            1,
            :count,
        )
        _performance_record!(
            records,
            metadata,
            profile,
            stage,
            :wall_time_before_failure,
            (time_ns() - started_at) / 1.0e9,
            :seconds,
        )
        _checkpoint_performance_records(checkpoint_path, records)
        rethrow()
    end
    measurements = Any[measurement]
    for _ in 2:samples
        sample_operation = isnothing(sample_factory) ?
                           operation :
                           sample_factory()
        push!(
            measurements,
            _timed_performance_operation(sample_operation),
        )
    end
    times = getproperty.(measurements, :time)
    memories = getproperty.(measurements, :bytes)
    allocations = _performance_allocation_count.(measurements)
    _performance_record!(
        records,
        metadata,
        profile,
        stage,
        :wall_time,
        measurement.time,
        :seconds,
    )
    _performance_record!(
        records,
        metadata,
        profile,
        stage,
        :median_time,
        median(times),
        :seconds,
    )
    _performance_record!(
        records,
        metadata,
        profile,
        stage,
        :minimum_time,
        minimum(times),
        :seconds,
    )
    _performance_record!(
        records,
        metadata,
        profile,
        stage,
        :allocated,
        measurement.bytes,
        :bytes,
    )
    _performance_record!(
        records,
        metadata,
        profile,
        stage,
        :median_memory,
        median(memories),
        :bytes,
    )
    _performance_record!(
        records,
        metadata,
        profile,
        stage,
        :minimum_memory,
        minimum(memories),
        :bytes,
    )
    _performance_record!(
        records,
        metadata,
        profile,
        stage,
        :allocations,
        allocations[1],
        :count,
    )
    _performance_record!(
        records,
        metadata,
        profile,
        stage,
        :median_allocations,
        median(allocations),
        :count,
    )
    _performance_record!(
        records,
        metadata,
        profile,
        stage,
        :minimum_allocations,
        minimum(allocations),
        :count,
    )
    _performance_record!(
        records,
        metadata,
        profile,
        stage,
        :samples,
        samples,
        :count,
    )
    _performance_record!(
        records,
        metadata,
        profile,
        stage,
        :gc_time,
        measurement.gctime,
        :seconds,
    )
    _checkpoint_performance_records(checkpoint_path, records)
    return measurement.value
end

function _record_runtime_performance!(
    records,
    metadata,
    profile,
    stage,
    simulation,
)
    performance = PlantSimEngine.Advanced.runtime_performance(simulation)
    isnothing(performance) && return records
    for (metric, value) in sort!(collect(performance.counts); by=first)
        _performance_record!(
            records,
            metadata,
            profile,
            stage,
            metric,
            value,
            :count,
        )
    end
    for (metric, value) in sort!(
        collect(performance.elapsed_seconds);
        by=first,
    )
        _performance_record!(
            records,
            metadata,
            profile,
            stage,
            metric,
            value,
            :seconds,
        )
    end
    return records
end

function _record_xpalm_state!(
    records,
    metadata,
    profile,
    stage,
    state,
)
    for metric in (:current_step, :phytomer_count, :lai, :ftsw)
        _performance_record!(
            records,
            metadata,
            profile,
            stage,
            metric,
            getproperty(state, metric),
            :value,
        )
    end
    return records
end

function _performance_steps(profile)
    profile == :smoke && return PERFORMANCE_SMOKE_STEPS
    profile == :short && return PERFORMANCE_SHORT_STEPS
    profile == :medium && return PERFORMANCE_MEDIUM_STEPS
    profile == :full && return PERFORMANCE_FULL_STEPS
    error(
        "Unsupported performance profile `$(profile)`. Use `:smoke`, `:short`, ",
        "`:medium`, or `:full`.",
    )
end

function _warmup_xpalm_performance!(profile_steps)
    lifecycle_steps = min(profile_steps, PERFORMANCE_SHORT_STEPS)
    no_output_model, no_output_steps =
        xpalm_reference_model_create(; nsteps=lifecycle_steps)
    xpalm_reference_param_run(
        no_output_model,
        OutputRequest[],
        no_output_steps;
        outputs=:none,
    )

    reference_model, reference_requests, reference_steps =
        xpalm_reference_param_create(; nsteps=PERFORMANCE_SMOKE_STEPS)
    reference_simulation = xpalm_reference_param_run(
        reference_model,
        reference_requests,
        reference_steps,
    )
    xpalm_default_param_collect_outputs(reference_simulation)
    return nothing
end

function run_xpalm_performance_profile(;
    profile=:short,
    checkpoint_path=nothing,
)
    normalized_profile = Symbol(profile)
    nsteps = _performance_steps(normalized_profile)
    warmup_policy =
        "unmeasured outputs=:none prefix ($(min(nsteps, PERFORMANCE_SHORT_STEPS)) steps) " *
        "plus requested-output smoke ($(PERFORMANCE_SMOKE_STEPS) steps)"
    _warmup_xpalm_performance!(nsteps)
    metadata = _performance_metadata(; warmup_policy=warmup_policy)
    records = NamedTuple[]

    compile_model, _ = xpalm_reference_model_create(; nsteps=nsteps)
    initial_compilation = _measure_performance_stage!(
        records,
        metadata,
        normalized_profile,
        :initial_scene_compilation,
        checkpoint_path,
        samples=PERFORMANCE_STATISTICAL_SAMPLES,
        sample_factory=() -> begin
            sample_model, _ =
                xpalm_reference_model_create(; nsteps=nsteps)
            return () ->
                PlantSimEngine.Advanced.refresh_bindings!(sample_model)
        end,
    ) do
        PlantSimEngine.Advanced.refresh_bindings!(compile_model)
    end
    _performance_record!(
        records,
        metadata,
        normalized_profile,
        :initial_scene_compilation,
        :application_count,
        length(initial_compilation.applications),
        :count,
    )

    steady_model, _ = xpalm_reference_model_create(; nsteps=2)
    steady_simulation = xpalm_reference_param_run(
        steady_model,
        OutputRequest[],
        1;
        outputs=:none,
    )
    steady_simulation = _measure_performance_stage!(
        records,
        metadata,
        normalized_profile,
        :clean_steady_state_step,
        checkpoint_path,
        samples=PERFORMANCE_STATISTICAL_SAMPLES,
        sample_factory=() -> begin
            sample_model, _ =
                xpalm_reference_model_create(; nsteps=2)
            sample_simulation = xpalm_reference_param_run(
                sample_model,
                OutputRequest[],
                1;
                outputs=:none,
            )
            return () -> continue!(sample_simulation)
        end,
    ) do
        continue!(steady_simulation)
    end
    current_step(steady_simulation) == 2 || error(
        "XPalm clean-step benchmark did not advance to step two.",
    )

    no_output_setup = _measure_performance_stage!(
        records,
        metadata,
        normalized_profile,
        :scene_construction_no_outputs,
        checkpoint_path,
        samples=PERFORMANCE_STATISTICAL_SAMPLES,
    ) do
        xpalm_reference_model_create(; nsteps=nsteps)
    end
    no_output_model, no_output_steps = no_output_setup
    no_output_simulation = _measure_performance_stage!(
        records,
        metadata,
        normalized_profile,
        :simulation_no_outputs,
        checkpoint_path,
        samples=PERFORMANCE_STATISTICAL_SAMPLES,
        sample_factory=() -> begin
            sample_model, sample_steps =
                xpalm_reference_model_create(; nsteps=nsteps)
            return () -> xpalm_reference_param_run(
                sample_model,
                OutputRequest[],
                sample_steps;
                outputs=:none,
                performance=true,
            )
        end,
    ) do
        xpalm_reference_param_run(
            no_output_model,
            OutputRequest[],
            no_output_steps;
            outputs=:none,
            performance=true,
        )
    end
    _record_runtime_performance!(
        records,
        metadata,
        normalized_profile,
        :simulation_no_outputs,
        no_output_simulation,
    )
    _checkpoint_performance_records(checkpoint_path, records)

    small_setup = _measure_performance_stage!(
        records,
        metadata,
        normalized_profile,
        :scene_and_request_compile_small_outputs,
        checkpoint_path,
        samples=PERFORMANCE_STATISTICAL_SAMPLES,
    ) do
        xpalm_small_param_create(; nsteps=nsteps)
    end
    small_model, small_requests, small_steps = small_setup
    small_simulation = _measure_performance_stage!(
        records,
        metadata,
        normalized_profile,
        :simulation_small_outputs,
        checkpoint_path,
        samples=PERFORMANCE_STATISTICAL_SAMPLES,
        sample_factory=() -> begin
            sample_model, sample_requests, sample_steps =
                xpalm_small_param_create(; nsteps=nsteps)
            return () -> xpalm_reference_param_run(
                sample_model,
                sample_requests,
                sample_steps;
                performance=true,
            )
        end,
    ) do
        xpalm_reference_param_run(
            small_model,
            small_requests,
            small_steps;
            performance=true,
        )
    end
    _record_runtime_performance!(
        records,
        metadata,
        normalized_profile,
        :simulation_small_outputs,
        small_simulation,
    )

    reference_setup = _measure_performance_stage!(
        records,
        metadata,
        normalized_profile,
        :scene_and_request_compile_reference_outputs,
        checkpoint_path,
        samples=PERFORMANCE_STATISTICAL_SAMPLES,
    ) do
        xpalm_reference_param_create(; nsteps=nsteps)
    end
    reference_model, reference_requests, reference_steps = reference_setup
    reference_simulation = _measure_performance_stage!(
        records,
        metadata,
        normalized_profile,
        :simulation_reference_outputs,
        checkpoint_path,
        samples=PERFORMANCE_STATISTICAL_SAMPLES,
        sample_factory=() -> begin
            sample_model, sample_requests, sample_steps =
                xpalm_reference_param_create(; nsteps=nsteps)
            return () -> xpalm_reference_param_run(
                sample_model,
                sample_requests,
                sample_steps;
                performance=true,
            )
        end,
    ) do
        xpalm_reference_param_run(
            reference_model,
            reference_requests,
            reference_steps;
            performance=true,
        )
    end
    reference_outputs = _measure_performance_stage!(
        records,
        metadata,
        normalized_profile,
        :collect_reference_outputs,
        checkpoint_path,
        samples=PERFORMANCE_STATISTICAL_SAMPLES,
    ) do
        xpalm_default_param_collect_outputs(reference_simulation)
    end
    _record_runtime_performance!(
        records,
        metadata,
        normalized_profile,
        :simulation_reference_outputs,
        reference_simulation,
    )

    all_output_setup = _measure_performance_stage!(
        records,
        metadata,
        normalized_profile,
        :scene_construction_all_outputs,
        checkpoint_path,
        samples=PERFORMANCE_STATISTICAL_SAMPLES,
    ) do
        xpalm_reference_model_create(; nsteps=nsteps)
    end
    all_output_model, all_output_steps = all_output_setup
    all_output_simulation = _measure_performance_stage!(
        records,
        metadata,
        normalized_profile,
        :simulation_all_outputs,
        checkpoint_path,
        samples=PERFORMANCE_STATISTICAL_SAMPLES,
        sample_factory=() -> begin
            sample_model, sample_steps =
                xpalm_reference_model_create(; nsteps=nsteps)
            return () -> xpalm_reference_param_run(
                sample_model,
                OutputRequest[],
                sample_steps;
                outputs=:all,
                performance=true,
            )
        end,
    ) do
        xpalm_reference_param_run(
            all_output_model,
            OutputRequest[],
            all_output_steps;
            outputs=:all,
            performance=true,
        )
    end
    _record_runtime_performance!(
        records,
        metadata,
        normalized_profile,
        :simulation_all_outputs,
        all_output_simulation,
    )

    no_output_state = xpalm_reference_final_state(no_output_simulation)
    small_state = xpalm_reference_final_state(small_simulation)
    reference_state = xpalm_reference_final_state(reference_simulation)
    all_output_state = xpalm_reference_final_state(all_output_simulation)
    _record_xpalm_state!(
        records,
        metadata,
        normalized_profile,
        :final_state_no_outputs,
        no_output_state,
    )
    _record_xpalm_state!(
        records,
        metadata,
        normalized_profile,
        :final_state_reference_outputs,
        reference_state,
    )
    _record_xpalm_state!(
        records,
        metadata,
        normalized_profile,
        :final_state_small_outputs,
        small_state,
    )
    _record_xpalm_state!(
        records,
        metadata,
        normalized_profile,
        :final_state_all_outputs,
        all_output_state,
    )
    _checkpoint_performance_records(checkpoint_path, records)
    no_output_state == small_state == reference_state == all_output_state || error(
        "XPalm performance fixtures diverged across output-retention modes: ",
        "none=$(no_output_state), small=$(small_state), ",
        "reference=$(reference_state), all=$(all_output_state).",
    )
    isempty(reference_outputs) && error(
        "XPalm performance reference output collection returned no tables.",
    )

    if normalized_profile == :full
        xpalm_reference_state_matches(reference_state) || error(
            "XPalm full-cycle performance fixture does not match the committed v0.6.1 final state: ",
            "$(reference_state).",
        )
        high_level_outputs = _measure_performance_stage!(
            records,
            metadata,
            normalized_profile,
            :historical_end_to_end_reference,
            checkpoint_path,
            samples=PERFORMANCE_STATISTICAL_SAMPLES,
        ) do
            xpalm_reference_end_to_end(; nsteps=nsteps)
        end
        xpalm_reference_high_level_state_matches(high_level_outputs) || error(
            "XPalm historical end-to-end performance fixture does not match the committed ",
            "v0.6.1 final state.",
        )
    end

    return (
        records=records,
        no_output_state=no_output_state,
        small_state=small_state,
        reference_state=reference_state,
        all_output_state=all_output_state,
    )
end

function write_xpalm_performance_profile(path; profile=:short)
    result = run_xpalm_performance_profile(;
        profile=profile,
        checkpoint_path=path,
    )
    _checkpoint_performance_records(path, result.records)
    return result
end

if abspath(PROGRAM_FILE) == @__FILE__
    profile = Symbol(get(ENV, "PSE_PERFORMANCE_PROFILE", "short"))
    default_name = "xpalm-$(profile)-$(Dates.format(Dates.now(), dateformat"yyyymmdd-HHMMSS")).csv"
    output_path = get(
        ENV,
        "PSE_PERFORMANCE_OUTPUT",
        joinpath(@__DIR__, "results", default_name),
    )
    result = write_xpalm_performance_profile(output_path; profile=profile)
    @info "XPalm performance profile complete" profile output_path final_state=result.reference_state
end
