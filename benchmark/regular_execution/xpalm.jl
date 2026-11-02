# Ordinary XPalm/PSE only. Run in the pinned XPalm project through Kaimon.
isdefined(@__MODULE__, :FullXPalmFixture) ||
    include(joinpath(@__DIR__, "..", "juliac_program", "app", "src", "full_xpalm_fixture.jl"))
isdefined(@__MODULE__, :OrdinaryObservations) || include(joinpath(@__DIR__, "observations.jl"))

module RegularXPalmExecution
using SHA, Serialization, Random
import PlantSimEngine as PSE
import XPalm
import MultiScaleTreeGraph as MTG
import ..FullXPalmFixture as Fixture
import ..OrdinaryObservations
const JSON = PSE.JSON
_timing(x) = (seconds=x.time, bytes=x.bytes, gctime=x.gctime,
    compile_seconds=x.compile_time, recompile_seconds=x.recompile_time)
function source_image(root)
    paths = sort!([joinpath(dir, name) for component in ("src", "ext") if isdir(joinpath(root, component))
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
function _raw_digest(value)
    io = IOBuffer()
    serialize(io, value)
    return bytes2hex(sha256(take!(io)))
end
# Canonical scalar records avoid uninitialized padding in arrays of isbits
# tuples such as (time::Float64, value::Bool). Float bits and types are retained.
_digest(value) = _raw_digest(OrdinaryObservations.canonical(value))
function _construct()
    palm = XPalm.Palm(; initiation_age=0, parameters=XPalm.default_parameters(), architecture=false)
    applications = Fixture.specs(palm)
    return (; palm, applications)
end
function _prepare(source, days, outputs)
    model = Fixture.scene(source.palm, Fixture.rows(days); applications=source.applications)
    return PSE.run!(model; steps=0, outputs, constants=PSE.Constants())
end
function snapshot(simulation)
    model = PSE.runtime_model(simulation)
    objects = sort!(collect(PSE.model_objects(model)); by=object -> object.id.value)
    states = [(id=object.id, state=NamedTuple(name => Fixture._plain(value)
        for (name, value) in pairs(PSE.final_state(simulation, object.id)) if name !== :node))
        for object in objects]
    topology = map(objects) do object
        node = PSE.source_node(model, object.id)
        (id=object.id, parent=object.parent, children=copy(object.children),
            scale=object.scale, kind=object.kind, species=object.species,
            link=MTG.link(node), index=MTG.index(node), level=MTG.scale(node))
    end
    histories = sort!([(key, samples=[(time, Fixture._plain(value)) for (time, value) in stream])
        for (key, stream) in PSE.outputs(simulation)]; by=row -> repr(row.key))
    rngs = [(application=spec.name, field=name, type=string(typeof(getfield(spec.model, name))),
        full_state_sha256=_raw_digest(copy(getfield(spec.model, name))))
        for spec in model.applications for name in fieldnames(typeof(spec.model))
        if getfield(spec.model, name) isa Random.AbstractRNG]
    return (step=PSE.current_step(simulation), states, topology, histories, rngs)
end
function trial(days, outputs)
    GC.gc()
    construction = @timed _construct()
    preparation = @timed _prepare(construction.value, days, outputs)
    execution = @timed PSE.continue!(preparation.value; steps=days)
    observation = snapshot(preparation.value)
    return (construction=_timing(construction), preparation=_timing(preparation), execution=_timing(execution),
        snapshot_sha256=_digest(observation), objects=length(observation.states),
        retained_samples=sum(length(row.samples) for row in observation.histories; init=0),
        reachable_simulation_bytes=Base.summarysize(preparation.value),
        rngs=observation.rngs), observation
end
function measure_case(; days=256, outputs=:none, samples=3, destination, baseline_directory=nothing)
    samples >= 3 || throw(ArgumentError("at least three measured samples required"))
    configuration=(; days, outputs, samples, initiation_age=0, architecture=false,
        parameters=:unchanged_package_defaults, forcing=:fixture_synthetic_daily)
    path = joinpath(destination, "xpalm-$(days)-$(outputs)")
    any(ispath, (path * ".json", path * ".snapshot")) &&
        error("choose a new result directory; existing cases are immutable")
    source_before=(pse=source_image(pkgdir(PSE)),xpalm=source_image(pkgdir(XPalm)),environment=environment_image())
    harness_paths=(driver_sha256=@__FILE__,
        observation_schema_sha256=joinpath(@__DIR__, "observations.jl"),
        fixture_sha256=joinpath(@__DIR__, "..", "juliac_program", "app", "src", "full_xpalm_fixture.jl"))
    harness_image() = NamedTuple{keys(harness_paths)}(map(
        path -> bytes2hex(sha256(read(path))), values(harness_paths),
    ))
    harness_before=harness_image()
    rows = NamedTuple[]
    warmup = nothing
    expected = isnothing(baseline_directory) ? nothing :
        open(deserialize, joinpath(baseline_directory, "xpalm-$(days)-$(outputs).snapshot"))
    expected_digest = isnothing(expected) ? nothing : _digest(expected)
    baseline_artifacts = if isnothing(baseline_directory)
        nothing
    else
        baseline_path=joinpath(baseline_directory, "xpalm-$(days)-$(outputs)")
        baseline=JSON.parsefile(baseline_path*".json")
        isequal(baseline["configuration"],JSON.parse(JSON.json(configuration))) ||
            error("baseline scenario configuration differs")
        isequal(baseline["source"]["xpalm"],JSON.parse(JSON.json(source_before.xpalm))) ||
            error("an engine comparison requires unchanged XPalm package sources")
        for name in (:observation_schema_sha256, :fixture_sha256)
            baseline[string(name)] == getproperty(harness_before, name) ||
                error("baseline benchmark schema or fixture differs: $(name)")
        end
        digest=expected_digest
        !isempty(baseline["samples"]) && all(row->row["snapshot_sha256"]==digest,baseline["samples"]) ||
            error("baseline snapshot differs from its checkpoint")
        (checkpoint_sha256=bytes2hex(sha256(read(baseline_path*".json"))),
            raw_snapshot_sha256=bytes2hex(sha256(read(baseline_path*".snapshot"))),snapshot_sha256=digest)
    end
    for index in 0:samples
        row, observation = trial(days, outputs)
        if isnothing(expected)
            expected = observation
            expected_digest = row.snapshot_sha256
        end
        isequal(observation, expected) || error("XPalm state/history/ordered topology/full RNG state differs from baseline")
        row.snapshot_sha256 == expected_digest || error("XPalm scientific types or floating-point bits differ from baseline")
        if index > 0
            all(phase -> iszero(phase.compile_seconds) && iszero(phase.recompile_seconds),
                (row.construction, row.preparation, row.execution)) ||
                error("measured trial compiled code; warm the exact path and use a fresh destination")
        end
        index == 0 ? (warmup = row) : push!(rows, row)
    end
    isequal(source_image(pkgdir(PSE)),source_before.pse) || error("PSE source changed during measurement")
    isequal(source_image(pkgdir(XPalm)),source_before.xpalm) || error("XPalm source changed during measurement")
    isequal(environment_image(),source_before.environment) || error("project environment changed during measurement")
    isequal(harness_image(),harness_before) || error("benchmark driver, schema or fixture changed during measurement")
    mkpath(destination)
    open(io -> serialize(io, expected), path * ".snapshot", "w")
    result = (configuration,
        executor=:ordinary_PSE, samples=rows, warmup,
        warmup_scope=:first_observation_in_current_process_not_a_fresh_cold_measurement,
        julia=string(VERSION), threads=Threads.nthreads(), cpu=Sys.CPU_NAME,
        pse_root=pkgdir(PSE), xpalm_root=pkgdir(XPalm),
        driver_sha256=harness_before.driver_sha256,
        observation_schema_sha256=harness_before.observation_schema_sha256,
        fixture_sha256=harness_before.fixture_sha256,
        source=source_before,baseline_directory,baseline_artifacts,exact_baseline_parity=!isnothing(baseline_directory),
        timing_boundary=:separate_authoring_preparation_complete_timeline_execution)
    write(path * ".json", JSON.json(result))
    return (case="$(days)-$(outputs)", execution_s=[row.execution.seconds for row in rows],
        preparation_s=[row.preparation.seconds for row in rows], objects=first(rows).objects)
end
function measure_matrix(; destination, baseline_directory=nothing, samples=3)
    rows = NamedTuple[]
    for (days, outputs) in ((256, :none), (256, :all), (1024, :none), (4160, :none))
        write(mkpath(destination) * "/stage.json", JSON.json((state=:running, days, outputs)))
        push!(rows, measure_case(; days, outputs, samples, destination, baseline_directory))
    end
    write(joinpath(destination, "summary.json"), JSON.json(rows))
    write(joinpath(destination, "stage.json"), JSON.json((state=:complete, cases=length(rows))))
    return length(rows)
end
end
