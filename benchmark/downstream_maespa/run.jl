module MAESPADownstreamBenchmark

using Dates, MAESPA, PlantSimEngine, SHA, Serialization, Statistics, TOML

const PSE = PlantSimEngine
const MAESPA_ROOT = pkgdir(MAESPA)
const EXAMPLE = joinpath(MAESPA_ROOT, "examples", "two_species.jl")
include(EXAMPLE)

"""Convert snapshots to package-independent values, preserving types and shapes."""
canonical(x::Union{Nothing,Missing,Symbol,AbstractString,Dates.TimeType,Dates.Period}) = x
canonical(x::Number) = (number_type=string(typeof(x)), value=x)
canonical(x::NamedTuple) = NamedTuple{keys(x)}(map(canonical, values(x)))
canonical(x::Tuple) = map(canonical, x)
canonical(x::Pair) = canonical(first(x)) => canonical(last(x))
canonical(x::AbstractArray) = (element_type=string(eltype(x)), shape=size(x),
    values=map(canonical, collect(vec(x))))
function canonical(x::AbstractDict)
    return [(key=canonical(k), value=canonical(v)) for (k, v) in
        sort!(collect(pairs(x)); by=pair -> repr(first(pair)))]
end
function canonical(x)
    names = fieldnames(typeof(x))
    return (type=string(typeof(x)), fields=NamedTuple{names}(
        map(name -> canonical(getfield(x, name)), names)))
end

function digest(value)
    io = IOBuffer()
    serialize(io, value)
    return bytes2hex(sha256(take!(io)))
end

file_digest(path) = bytes2hex(sha256(read(path)))
function source_hashes(root)
    paths = String[joinpath(root, "Project.toml")]
    for (directory, _, files) in walkdir(joinpath(root, "src")), file in files
        endswith(file, ".jl") && push!(paths, joinpath(directory, file))
    end
    root == MAESPA_ROOT && push!(paths, EXAMPLE)
    return Dict(relpath(path, root) => file_digest(path) for path in sort!(paths))
end

function git_revision(root)
    try
        return readchomp(`git -C $root rev-parse HEAD`)
    catch
        return "not a git checkout"
    end
end

function provenance(label)
    project = Base.active_project()
    manifest = joinpath(dirname(project), "Manifest.toml")
    options = Base.JLOptions()
    launch_settings = Dict(string(name) => getproperty(options, name) for name in
        (:compile_enabled, :opt_level, :debug_level, :check_bounds, :can_inline,
            :fast_math, :use_compiled_modules, :startupfile) if hasproperty(options, name))
    runner_paths = (@__FILE__, joinpath(@__DIR__, "prepared_calls.jl"))
    return (
        label=label,
        julia_version=string(VERSION),
        compute_threads=Threads.nthreads(),
        interactive_threads=Threads.nthreads(:interactive),
        gc_threads=isdefined(Threads, :ngcthreads) ? Threads.ngcthreads() : "unavailable",
        launch_settings=launch_settings,
        runner_sources=Dict(basename(path) => file_digest(path) for path in runner_paths),
        cpu=Sys.CPU_NAME,
        machine=Sys.MACHINE,
        active_project=project,
        project_sha256=file_digest(project),
        manifest_sha256=isfile(manifest) ? file_digest(manifest) : "absent",
        pse_path=Base.pathof(PSE),
        pse_version=string(Base.pkgversion(PSE)),
        pse_revision=git_revision(pkgdir(PSE)),
        maespa_path=Base.pathof(MAESPA),
        maespa_version=string(Base.pkgversion(MAESPA)),
        maespa_revision=git_revision(MAESPA_ROOT),
        pse_sources=source_hashes(pkgdir(PSE)),
        maespa_sources=source_hashes(MAESPA_ROOT),
    )
end

function plain(x::NamedTuple)
    return Dict(string(k) => plain(v) for (k, v) in pairs(x))
end
plain(x::AbstractDict) = Dict(string(k) => plain(v) for (k, v) in pairs(x))
plain(x::Union{Tuple,AbstractVector}) = [plain(v) for v in x]
plain(x::Symbol) = string(x)
plain(::Nothing) = "nothing"
plain(x) = x

function save_toml(path, value)
    open(path, "w") do io
        TOML.print(io, plain(value); sorted=true)
    end
end

function metrics(timed)
    return (
        seconds=timed.time,
        allocated_bytes=timed.bytes,
        gc_seconds=timed.gctime,
        compilation_seconds=timed.compile_time,
        recompilation_seconds=timed.recompile_time,
    )
end

function check_result(simulation)
    @assert PSE.current_step(simulation) == 96
    soil = PSE.final_state(simulation, :soil)
    @assert soil.soil_water_balance_available
    @assert abs(soil.soil_water_mass_balance_residual_m) < 1e-7
    for id in (:crown_1, :crown_2)
        crown = PSE.final_state(simulation, id)
        @assert crown.crown_leaf_exchange_aggregation_available
        @assert isfinite(crown.net_assimilation_crown_umol_co2_s)
        @assert isfinite(crown.mean_leaf_temperature_crown_c)
    end
    return (
        steps=PSE.current_step(simulation),
        soil_storage_m=soil.soil_storage_after_m,
        water_residual_m=soil.soil_water_mass_balance_residual_m,
    )
end

"""Complete public final states and every retained publication, outside timings."""
function snapshot(simulation; history=false)
    objects = sort!(collect(PSE.model_objects(simulation.model)); by=o -> repr(o.id.value))
    states = [(object_id=canonical(object.id.value),
        status=canonical(PSE.final_state(simulation, object.id.value))) for object in objects]
    rows = history ? PSE.collect_outputs(simulation; sink=nothing) : NamedTuple[]
    sort!(rows; by=row -> (row.timestep, repr(row.application_id),
        repr(row.object_id), repr(row.variable)))
    return (steps=PSE.current_step(simulation), states=states, rows=canonical(rows))
end

function measure_once(; outputs=:none)
    GC.gc()
    built = @timed two_species_model()
    started = @timed PSE.run!(built.value; steps=0, outputs=outputs)
    stepped = @timed PSE.continue!(started.value; steps=96)
    checked = check_result(started.value)
    return (build=metrics(built), startup=metrics(started),
        stepping=metrics(stepped), check=checked), started.value
end

function phase_medians(records)
    return Dict(string(phase) => (
        seconds=median(getproperty(record, phase).seconds for record in records),
        allocated_bytes=median(getproperty(record, phase).allocated_bytes for record in records),
        gc_seconds=median(getproperty(record, phase).gc_seconds for record in records),
        max_compilation_seconds=maximum(
            getproperty(record, phase).compilation_seconds for record in records),
        max_recompilation_seconds=maximum(
            getproperty(record, phase).recompilation_seconds for record in records),
    ) for phase in (:build, :startup, :stepping))
end

"""
    run_benchmark(label, output_directory; reference=nothing, repetitions=5)

Run this same file in separate Kaimon-controlled Julia processes for the
registered release, parent revision and candidate. Dependencies must already be
prepared in the active temporary project. Package load and example inclusion
precede every timing. Full source hashes are checked again before completion.
"""
function run_benchmark(label, output_directory; reference=nothing, repetitions=5,
    output_modes=(:none, :all), cancelled=() -> false)
    repetitions > 0 || throw(ArgumentError("repetitions must be positive"))
    mkpath(output_directory)
    before = provenance(label)
    @assert Base.pathof(MAESPA) == joinpath(MAESPA_ROOT, "src", "MAESPA.jl")
    records = Dict{String,Any}("provenance" => before)
    record_path = joinpath(output_directory, "measurements.toml")
    snapshot_path = joinpath(output_directory, "complete_snapshot.jls")
    @info "MAESPA benchmark first complete pass" label
    first_pass, initial = measure_once()
    records["first_pass"] = first_pass
    base_state = snapshot(initial)
    records["scenario"] = (
        objects=length(PSE.model_objects(initial.model)),
        applications=length(PSE.Diagnostics.explain_applications(initial.model)),
        logical_leaf_units=count(o -> o.scale === :LogicalLeafUnit,
            PSE.model_objects(initial.model)),
    )
    initial = nothing
    save_toml(record_path, records)

    full_snapshot_written = false
    for output_mode in output_modes
        output_mode in (:none, :all) || throw(ArgumentError("unsupported output mode"))
        @info "MAESPA benchmark warmup" label output_mode
        warmup, simulation = measure_once(; outputs=output_mode)
        warm_snapshot = snapshot(simulation; history=output_mode === :all)
        @assert isequal(warm_snapshot.states, base_state.states)
        if output_mode === :all
            serialize(snapshot_path, warm_snapshot)
            full_snapshot_written = true
        end
        warm_snapshot = nothing
        simulation = nothing
        samples = NamedTuple[]
        for repetition in 1:repetitions
            cancelled() && error("benchmark cancelled before repetition $repetition")
            @info "MAESPA benchmark sample" label output_mode repetition repetitions
            record, simulation = measure_once(; outputs=output_mode)
            sampled = snapshot(simulation; history=output_mode === :all)
            @assert isequal(sampled.states, base_state.states)
            if output_mode === :all
                expected = deserialize(snapshot_path)
                @assert isequal(sampled, expected)
                expected = nothing
            end
            push!(samples, record)
            simulation = nothing
            sampled = nothing
            records[string(output_mode)] = (warmup=warmup, samples=samples,
                medians=phase_medians(samples))
            save_toml(record_path, records)
        end
    end
    full_snapshot_written || error("include :all once to verify complete publication history")
    full_snapshot = deserialize(snapshot_path)
    if !isnothing(reference)
        expected = deserialize(reference)
        @assert isequal(full_snapshot, expected) "complete final states/publications differ from reference"
    end
    after = provenance(label)
    @assert before.pse_sources == after.pse_sources "PSE source changed during measurement"
    @assert before.maespa_sources == after.maespa_sources "MAESPA source changed during measurement"
    @assert before.manifest_sha256 == after.manifest_sha256 "active manifest changed during measurement"
    @assert before.runner_sources == after.runner_sources "benchmark runners changed during measurement"
    records["correctness"] = (
        exact_reference_match=!isnothing(reference),
        reference=isnothing(reference) ? "first reference producer" : abspath(reference),
        snapshot_sha256=file_digest(snapshot_path),
        checked_objects=length(full_snapshot.states),
        retained_publication_rows=length(full_snapshot.rows.values),
        source_hashes_unchanged=true,
        manifest_unchanged=true,
    )
    save_toml(record_path, records)
    return (label=label, output_directory=abspath(output_directory),
        no_output_medians=haskey(records, "none") ? records["none"].medians : nothing,
        all_output_medians=records["all"].medians,
        correctness=records["correctness"])
end

end
