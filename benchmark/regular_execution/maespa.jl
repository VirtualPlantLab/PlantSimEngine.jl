# Load in a project that develops the chosen PSE and MAESPA revisions together.
# This driver uses only ordinary run!/continue!, with no JuliaC dependency.
isdefined(@__MODULE__, :DownstreamMAESPAFixture) ||
    include(joinpath(@__DIR__, "..", "juliac_program", "downstream_maespa_fixture.jl"))
isdefined(@__MODULE__, :DownstreamMAESPAEncoding) ||
    include(joinpath(@__DIR__, "..", "juliac_program", "downstream_maespa_encoding.jl"))

isdefined(@__MODULE__, :OrdinaryObservations) || include(joinpath(@__DIR__, "observations.jl"))

module RegularMAESPAExecution
using Dates, SHA, Serialization
import PlantSimEngine as PSE
import ..DownstreamMAESPAFixture as Fixture
import ..DownstreamMAESPAEncoding as Encoding
const JSON = PSE.JSON

using ..OrdinaryObservations: canonical, TYPE_LABELS

function snapshot(simulation, fixture)
    objects=sort!(collect(PSE.model_objects(simulation.model)); by=object -> repr(object.id.value))
    states=[(object_id=canonical(object.id.value), status=canonical(PSE.final_state(simulation, object.id))) for object in objects]
    topology=[(object_id=canonical(object.id.value), parent=canonical(object.parent), children=canonical(object.children),
        scale=object.scale, kind=object.kind, species=object.species, geometry=canonical(PSE.geometry(object))) for object in objects]
    history=sort!([(key=canonical(key), samples=[(time=canonical(first(sample)), value=canonical(last(sample))) for sample in stream])
        for (key, stream) in pairs(PSE.outputs(simulation))]; by=row -> repr(row.key))
    return (step=PSE.current_step(simulation), states, topology, history,
        committed_canopy=canonical(simulation.model.environment.canopy), scientific_rngs=Fixture.scientific_rngs(simulation.model, fixture))
end

_safe(x::Type) = string(x)
_safe(x::NamedTuple) = NamedTuple{keys(x)}(map(_safe, values(x)))
_safe(x::Tuple) = map(_safe, x)
_safe(x::AbstractArray) = map(_safe, x)
_safe(x::AbstractDict) = Dict(k => _safe(v) for (k, v) in x)
_safe(x::AbstractFloat) = isfinite(x) ? x : (type=string(typeof(x)), special=string(x))
_safe(x) = x
function _write(path, value)
    mkpath(dirname(path))
    write(path * ".partial", JSON.json(_safe(value)))
    mv(path * ".partial", path; force=true)
end
function source_image(root)
    paths = sort!([joinpath(dir, name) for component in ("src", "ext")
        for (dir, _, files) in walkdir(joinpath(root, component))
        for name in files if endswith(name, ".jl")])
    push!(paths, joinpath(root, "Project.toml"))
    return [(path=relpath(path, root), sha256=bytes2hex(sha256(read(path)))) for path in paths]
end
function environment_image()
    project = Base.active_project()
    paths = filter(isfile, [project, joinpath(dirname(project), "Manifest.toml"),
        joinpath(dirname(project), "Manifest-v$(VERSION.major).$(VERSION.minor).toml")])
    return [(path, sha256=bytes2hex(sha256(read(path)))) for path in paths]
end
function _snapshot_hash(value)
    io = IOBuffer()
    serialize(io, value)
    return bytes2hex(sha256(take!(io)))
end
_timing(x) = (seconds=x.time, bytes=x.bytes, gctime=x.gctime,
    compile_seconds=x.compile_time, recompile_seconds=x.recompile_time)
_typed_ids(ids) = isempty(ids) ? PSE.ObjectId{Symbol}[] : typeof(first(ids))[id for id in ids]
function records(simulation)
    io = IOBuffer()
    objects = collect(PSE.model_objects(simulation.model))
    Encoding.encode_record(io, ("F", PSE.current_step(simulation), length(simulation.model.applications), length(objects)))
    for object in objects
        Encoding.encode_record(io, ("T", object.id, object.parent, _typed_ids(object.children),
            object.scale, object.kind, object.species, PSE.geometry(object)))
        for (name, value) in pairs(PSE.final_state(simulation, object.id))
            Encoding.encode_record(io, ("S", object.id, name, value))
        end
    end
    for ((application, id, variable), stream) in PSE.outputs(simulation)
        Encoding.encode_record(io, ("H", application, id, variable))
        for (time, value) in stream
            Encoding.encode_record(io, ("O", application, id, time, variable, value))
        end
    end
    Encoding.encode_record(io, ("E", simulation.model.environment.canopy))
    return sort!(split(String(take!(io)), '\n'; keepempty=false))
end
function trial(config)
    GC.gc()
    construction = @timed Fixture.construct(config)
    preparation = @timed Fixture.ordinary_start(construction.value)
    execution = @timed Fixture.ordinary_advance!(preparation.value, config.steps)
    state_snapshot = snapshot(preparation.value, construction.value)
    observation = records(preparation.value)
    groups = preparation.value.execution_plan.groups
    concrete = count(group -> isconcretetype(eltype(group.batches)), groups)
    row = (construction=_timing(construction), preparation=_timing(preparation), execution=_timing(execution),
        snapshot_sha256=_snapshot_hash(state_snapshot), record_sha256=bytes2hex(sha256(join(observation, '\n'))),
        work=Fixture.work_witness(preparation.value),
        reachable_simulation_bytes=Base.summarysize(preparation.value),
        executor=(application_groups=length(groups), concrete_batch_groups=concrete))
    return row, observation
end

"""Measure fresh ordinary scenarios, validating every measured sample against a frozen control.

Construction, preparation and full-timeline execution have separate clocks.
The first trial warms Julia and is excluded. Snapshotting, record formatting,
source inventory checks and GC before each construction are outside the clocks.
"""
function measure_case(; copies=1, steps=24, start_slot=13, outputs=:all, samples=3,
    destination, baseline_directory=nothing)
    samples >= 3 || throw(ArgumentError("at least three measured samples required"))
    config = Fixture.configuration(; copies, steps, start_slot, outputs)
    label = "$(copies)-$(steps)-$(outputs)"
    records_path = joinpath(destination, "maespa-$(label).records")
    result_path = joinpath(destination, "maespa-$(label).json")
    any(ispath, (records_path, result_path)) && error("choose a new result directory; existing cases are immutable")
    pse_before = source_image(pkgdir(PSE))
    science_before = Fixture.source_snapshot()
    environment_before = environment_image()
    harness_paths=(driver_sha256=@__FILE__,
        observation_schema_sha256=joinpath(@__DIR__, "observations.jl"),
        fixture_sha256=joinpath(@__DIR__, "..", "juliac_program", "downstream_maespa_fixture.jl"),
        codec_sha256=joinpath(@__DIR__, "..", "juliac_program", "downstream_maespa_encoding.jl"))
    harness_image() = NamedTuple{keys(harness_paths)}(map(
        path -> bytes2hex(sha256(read(path))), values(harness_paths),
    ))
    harness_before=harness_image()
    baseline = isnothing(baseline_directory) ? nothing :
        JSON.parsefile(joinpath(baseline_directory, "maespa-$(label).json"))
    expected = isnothing(baseline_directory) ? nothing :
        readlines(joinpath(baseline_directory, "maespa-$(label).records"))
    baseline_artifacts = if isnothing(baseline_directory)
        nothing
    else
        isequal(baseline["configuration"], JSON.parse(JSON.json(_safe(config)))) ||
            error("baseline scenario configuration differs")
        baseline["source"]["aggregate_sha256"] == science_before.aggregate_sha256 ||
            error("an engine comparison requires unchanged scientific package sources")
        for name in (:observation_schema_sha256, :fixture_sha256, :codec_sha256)
            baseline[string(name)] == getproperty(harness_before, name) ||
                error("baseline benchmark schema, fixture or codec differs: $(name)")
        end
        issorted(expected) || error("baseline records are not in canonical sorted order")
        digest = bytes2hex(sha256(join(expected, '\n')))
        baseline["record_count"] == length(expected) || error("baseline record count differs from its checkpoint")
        !isempty(baseline["samples"]) && all(row -> row["record_sha256"] == digest, baseline["samples"]) ||
            error("baseline raw record hash differs from its checkpoint")
        (checkpoint_sha256=bytes2hex(sha256(read(joinpath(baseline_directory, "maespa-$(label).json")))),
            raw_file_sha256=bytes2hex(sha256(read(joinpath(baseline_directory, "maespa-$(label).records")))),
            record_sha256=digest)
    end
    rows = NamedTuple[]
    warmup = nothing
    for index in 0:samples
        row, observation = trial(config)
        isnothing(expected) && (expected = observation)
        isequal(observation, expected) || error("ordinary scientific records differ from the frozen baseline")
        if !isnothing(baseline)
            all(sample -> sample["snapshot_sha256"] == row.snapshot_sha256, baseline["samples"]) ||
                error("ordinary state/history/topology/geometry/committed atmosphere/RNG snapshot differs")
        end
        if index > 0
            all(phase -> iszero(phase.compile_seconds) && iszero(phase.recompile_seconds),
                (row.construction, row.preparation, row.execution)) ||
                error("measured trial compiled code; warm the exact path and use a fresh destination")
        end
        index == 0 ? (warmup = row) : push!(rows, row)
    end
    isequal(source_image(pkgdir(PSE)), pse_before) || error("PSE source changed during measurement")
    isequal(Fixture.source_snapshot(), science_before) || error("MAESPA source changed during measurement")
    isequal(environment_image(), environment_before) || error("project environment changed during measurement")
    isequal(harness_image(),harness_before) || error("benchmark driver, schema, fixture or codec changed during measurement")
    mkpath(destination)
    open(io -> foreach(line -> println(io, line), expected), records_path, "w")
    result = (configuration=config, executor=:ordinary_PSE, samples=rows, warmup,
        warmup_scope=:first_observation_in_current_process_not_a_fresh_cold_measurement,
        driver_sha256=harness_before.driver_sha256,
        observation_schema_sha256=harness_before.observation_schema_sha256,
        fixture_sha256=harness_before.fixture_sha256,
        codec_sha256=harness_before.codec_sha256,
        pse_root=pkgdir(PSE), pse_source=pse_before, source=science_before,
        julia=string(VERSION), threads=Threads.nthreads(), cpu=Sys.CPU_NAME,
        environment=environment_before, baseline_directory, baseline_artifacts,
        exact_baseline_parity=!isnothing(baseline),
        record_count=length(expected), records_path,
        timing_boundary=:separate_construction_preparation_complete_timeline_execution,
        compilation=:one_untimed_warmup_excluded)
    _write(result_path, result)
    return (case=label, execution_s=[row.execution.seconds for row in rows],
        preparation_s=[row.preparation.seconds for row in rows],
        construction_s=[row.construction.seconds for row in rows], record_count=length(expected))
end
function measure_matrix(; destination, baseline_directory=nothing, samples=3)
    rows = NamedTuple[]
    for copies in (1, 4), (steps, start_slot) in ((24, 13), (96, 1)), outputs in (:none, :all)
        _write(joinpath(destination, "stage.json"), (state=:running, copies, steps, outputs))
        push!(rows, measure_case(; copies, steps, start_slot, outputs, samples, destination, baseline_directory))
    end
    _write(joinpath(destination, "summary.json"), rows)
    _write(joinpath(destination, "stage.json"), (state=:complete, cases=length(rows)))
    return length(rows)
end
end
