using CSV
using DataFrames
using Dates
using PlantSimEngine
using XPalm

isdefined(@__MODULE__, :xpalm_reference_param_create) ||
    include(joinpath(@__DIR__, "test-xpalm.jl"))

const PERFORMANCE_SMOKE_STEPS = 2
const PERFORMANCE_SHORT_STEPS = 100
const PERFORMANCE_FULL_STEPS = 4160

function _performance_git_revision(path)
    try
        return readchomp(`git -C $path rev-parse HEAD`)
    catch
        return "unknown"
    end
end

function _performance_metadata()
    pse_root = dirname(@__DIR__)
    xpalm_root = dirname(dirname(pathof(XPalm)))
    return (
        recorded_at=Dates.format(Dates.now(), dateformat"yyyy-mm-ddTHH:MM:SS.sss"),
        julia_version=string(VERSION),
        machine=Sys.MACHINE,
        cpu=Sys.CPU_NAME,
        threads=Threads.nthreads(),
        plantsimengine_revision=_performance_git_revision(pse_root),
        xpalm_revision=_performance_git_revision(xpalm_root),
    )
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

function _measure_performance_stage!(
    records,
    metadata,
    profile,
    stage,
    operation,
)
    GC.gc()
    measurement = @timed operation()
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
        :allocated,
        measurement.bytes,
        :bytes,
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

function _performance_steps(profile)
    profile == :smoke && return PERFORMANCE_SMOKE_STEPS
    profile == :short && return PERFORMANCE_SHORT_STEPS
    profile == :full && return PERFORMANCE_FULL_STEPS
    error(
        "Unsupported performance profile `$(profile)`. Use `:smoke`, `:short`, or `:full`.",
    )
end

function run_xpalm_performance_profile(; profile=:short)
    normalized_profile = Symbol(profile)
    nsteps = _performance_steps(normalized_profile)
    metadata = _performance_metadata()
    records = NamedTuple[]

    no_output_setup = _measure_performance_stage!(
        records,
        metadata,
        normalized_profile,
        :scene_construction_no_outputs,
    ) do
        xpalm_reference_model_create(; nsteps=nsteps)
    end
    no_output_model, no_output_steps = no_output_setup
    no_output_simulation = _measure_performance_stage!(
        records,
        metadata,
        normalized_profile,
        :simulation_no_outputs,
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

    reference_setup = _measure_performance_stage!(
        records,
        metadata,
        normalized_profile,
        :scene_and_request_compile_reference_outputs,
    ) do
        xpalm_reference_param_create(; nsteps=nsteps)
    end
    reference_model, reference_requests, reference_steps = reference_setup
    reference_simulation = _measure_performance_stage!(
        records,
        metadata,
        normalized_profile,
        :simulation_reference_outputs,
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

    no_output_state = xpalm_reference_final_state(no_output_simulation)
    reference_state = xpalm_reference_final_state(reference_simulation)
    no_output_state == reference_state || error(
        "XPalm performance fixtures diverged between `outputs=:none` and reference outputs: ",
        "$(no_output_state) != $(reference_state).",
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
        reference_state=reference_state,
    )
end

function write_xpalm_performance_profile(path; profile=:short)
    result = run_xpalm_performance_profile(; profile=profile)
    mkpath(dirname(path))
    CSV.write(path, DataFrame(result.records))
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
