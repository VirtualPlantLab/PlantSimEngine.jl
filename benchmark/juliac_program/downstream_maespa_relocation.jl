isdefined(@__MODULE__, :DownstreamMAESPARegistry) || include(joinpath(@__DIR__, "downstream_maespa_registry.jl"))
isdefined(@__MODULE__, :DownstreamMAESPAProvenance) || include(joinpath(@__DIR__, "downstream_maespa_provenance.jl"))

module DownstreamMAESPARelocation

using SHA
import ..DownstreamMAESPAFixture as Fixture
import ..DownstreamMAESPARegistry as Adapter
import ..DownstreamMAESPAProvenance as Provenance

const JSON = Fixture.PSE.JSON
const RECORD_KINDS = ("F", "T", "S", "H", "O", "E")
const UNSET_ENVIRONMENT = (
    "JULIA_PROJECT", "JULIA_LOAD_PATH", "PSE_MAESPA_PATH",
    "PSE_MAESPA_BUILD_DIR", "PSE_MAESPA_BUILD_PROFILE",
)

_file_sha256(path) = open(io -> bytes2hex(sha256(io)), path, "r")
_records_sha256(rows) = bytes2hex(sha256(join(rows, '\n')))
_inside(path, root) = first(splitpath(relpath(path, root))) != ".."

_json_safe(value::Type) = string(value)
_json_safe(value::Symbol) = String(value)
_json_safe(value::NamedTuple) = Dict(String(name) => _json_safe(item) for (name, item) in pairs(value))
_json_safe(value::Tuple) = map(_json_safe, value)
_json_safe(value::AbstractArray) = map(_json_safe, value)
_json_safe(value::AbstractDict) = Dict(string(name) => _json_safe(item) for (name, item) in value)
_json_safe(value::AbstractFloat) = isfinite(value) ? value : (type=string(typeof(value)), special=string(value))
_json_safe(value) = value

function _write_json(path, value)
    write(path, JSON.json(_json_safe(value)))
    return path
end

"""Inventory every bundled file and link, including bundled libraries/artifacts.

Relative symlinks are preserved by the copy. Links escaping the bundle, dangling
links, and special files are rejected rather than counted as self-contained.
This inventory does not inspect the executable's system-library dependencies.
"""
function _bundle_inventory(bundle)
    root = realpath(bundle)
    rows = NamedTuple{(:path, :kind, :target, :bytes, :sha256), Tuple{String, String, String, Int, String}}[]
    for (parent, directories, files) in walkdir(root; follow_symlinks=false)
        for name in sort!(vcat(directories, files))
            path = joinpath(parent, name)
            relative = relpath(path, root)
            if islink(path)
                target = readlink(path)
                isabspath(target) && error("relocation requires relative bundled symlinks: $relative")
                _inside(realpath(path), root) || error("bundled symlink escapes the relocation tree: $relative")
                push!(rows, (path=relative, kind="symlink", target, bytes=0, sha256=""))
            elseif isdir(path)
                push!(rows, (path=relative, kind="directory", target="", bytes=0, sha256=""))
            elseif isfile(path)
                push!(rows, (path=relative, kind="file", target="", bytes=Int(filesize(path)), sha256=_file_sha256(path)))
            else
                error("unsupported special file in native bundle: $relative")
            end
        end
    end
    sort!(rows; by=row -> row.path)
    aggregate = bytes2hex(sha256(join((row.path * "\0" * row.kind * "\0" * row.target * "\0" *
        string(row.bytes) * "\0" * row.sha256 for row in rows), '\n')))
    return (aggregate_sha256=aggregate, files=count(row -> row.kind == "file", rows),
        symlinks=count(row -> row.kind == "symlink", rows),
        directories=count(row -> row.kind == "directory", rows),
        bytes=sum(row.bytes for row in rows; init=0), entries=rows)
end

function _read_records(path)
    rows = sort!(readlines(path))
    isempty(rows) && error("full scientific observations are empty")
    encoding = Adapter.Registry.RegistryEncoding
    prefixes = [kind => encoding.record_prefix(kind) for kind in RECORD_KINDS]
    all(row -> any(pair -> startswith(row, last(pair)), prefixes), rows) ||
        error("unexpected record in full scientific observations")
    counts = Dict(kind => count(row -> startswith(row, prefix), rows) for (kind, prefix) in prefixes)
    counts["F"] == 1 && counts["E"] == 1 && counts["T"] > 0 && counts["S"] > 0 ||
        error("incomplete final state/topology/environment observations")
    return (rows, counts, record_count=length(rows), record_sha256=_records_sha256(rows),
        records_file_sha256=_file_sha256(path))
end

function _fresh_original(config, path)
    fixture = Fixture.construct(config)
    simulation = Fixture.ordinary_start(fixture)
    Fixture.ordinary_advance!(simulation, config.steps)
    open(io -> Adapter.print_ordinary(simulation, io), path, "w")
    return (kind=:fresh_original_ordinary_PSE, records_path=path,
        work=Fixture.work_witness(simulation), configuration=config)
end

function _accepted_checkpoint(checkpoint, checkpoint_records, config, source, destination)
    path = abspath(checkpoint)
    report = JSON.parsefile(path)
    measurement = report["measurement"]
    measurement["executor"] == "ordinary_PSE" && measurement["source_variant"] == "original" &&
        report["loaded_source_variant"] == "original" || error("checkpoint is not an original ordinary baseline")
    measurement["configuration"] == _json_safe(config) || error("checkpoint has another scientific configuration")
    measurement["source"]["aggregate_sha256"] == source.aggregate_sha256 || error("checkpoint has another scientific source")
    report["formatter_records"] == collect(RECORD_KINDS) || error("checkpoint has another full-record schema")
    codec = joinpath(@__DIR__, "downstream_maespa_encoding.jl")
    report["codec_sha256"] == _file_sha256(codec) || error("checkpoint observation codec differs from this qualification")
    original_records = abspath(isnothing(checkpoint_records) ? measurement["records_path"] : checkpoint_records)
    isfile(original_records) || error("accepted checkpoint's raw records are unavailable")
    haskey(report, "records_file_sha256") || error("accepted checkpoint omits its raw-record file hash")
    _file_sha256(original_records) == report["records_file_sha256"] || error("accepted checkpoint's raw records changed")
    records = _read_records(original_records)
    records.record_count == measurement["record_count"] || error("accepted checkpoint record count differs")
    !isempty(measurement["samples"]) && all(sample -> sample["record_sha256"] == records.record_sha256,
        measurement["samples"]) || error("accepted checkpoint samples disagree with its full records")
    cp(original_records, destination)
    return (kind=:accepted_original_ordinary_PSE_checkpoint, checkpoint=path,
        checkpoint_sha256=_file_sha256(path), original_records_path=original_records,
        original_records_file_sha256=records.records_file_sha256, records_path=destination,
        configuration=config)
end

function _require_unchanged_inventory(before, bundle)
    after = _bundle_inventory(bundle)
    isequal(after, before) || error("native bundle contents changed during relocation qualification")
    return nothing
end

"""
    check_relocation(bundle; config=Fixture.configuration(), checkpoint=nothing,
                     checkpoint_records=nothing, scratch_parent="/private/tmp")

Qualify an already built, provenance-verified JuliaC **safe/generic** MAESPA
bundle after copying it to a fresh temporary directory on the same host. Run
this host helper from a Kaimon-controlled Julia session with the untouched
original MAESPA source loaded. The helper launches the copied native executable;
it does not launch another Julia process, rebuild, or modify the accepted bundle.

The copied launcher runs `emit` from an empty working directory with a fresh
HOME, an empty external depot, and JULIA_PROJECT/JULIA_LOAD_PATH unset. The
launcher sets JULIA_DEPOT_PATH to the copied bundle's `share/julia`, which contains
its bundled artifacts. Exact sorted F/T/S/H/O/E records must match either a fresh
original ordinary PSE run (the default) or an accepted original checkpoint. A
checkpoint additionally needs its JSON metadata and hash-verified raw records;
`checkpoint_records` can relocate that raw file without changing its hash.

Scientific/PSE provenance and every bundled file/link are checked before and
after the native invocation. Artifacts and a JSON report remain in the returned
scratch directory, outside Git. This is a relocation/record-parity check, not a
timing benchmark or a cross-host portability check. System libraries and the
authoring source directories remain available on the host; their inaccessibility
is not tested. The admitted suite has no runtime RNGs, as required by its build
provenance; this helper adds no stochastic-model coverage.

From an already configured Kaimon session, for example:

```julia
include(joinpath(repo, "benchmark", "juliac_program", "downstream_maespa_relocation.jl"))
cfg = DownstreamMAESPAFixture.configuration(steps=24, copies=1, start_slot=13, outputs=:all)
relocation = DownstreamMAESPARelocation.check_relocation(verified_bundle; config=cfg)
# Return only (relocation.report_path, relocation.record_count) through Kaimon.
```
"""
function check_relocation(bundle; config=Fixture.configuration(), checkpoint=nothing,
    checkpoint_records=nothing, scratch_parent="/private/tmp")
    config.T === Float64 || throw(ArgumentError("the native MAESPA suite is authored for Float64"))
    isnothing(checkpoint) && !isnothing(checkpoint_records) &&
        throw(ArgumentError("checkpoint_records requires an accepted checkpoint"))
    root = realpath(bundle)
    parent = realpath(scratch_parent)
    _inside(parent, root) && throw(ArgumentError("relocation scratch must be outside the accepted bundle"))
    source = Fixture.source_snapshot()
    original = Provenance.verify_bundle(root, source; variant=:original)
    Provenance.require_case(original, config)
    inventory = _bundle_inventory(root)

    scratch = mktempdir(parent; prefix="maespa-relocation-", cleanup=false)
    relocated = joinpath(scratch, "bundle")
    home = joinpath(scratch, "home")
    external_depot = joinpath(scratch, "external-depot")
    cwd = joinpath(scratch, "cwd")
    records_directory = joinpath(scratch, "records")
    foreach(mkdir, (home, external_depot, cwd, records_directory))
    inventory_path = _write_json(joinpath(scratch, "bundle-inventory.json"), inventory)
    cp(root, relocated; follow_symlinks=false)
    copied = Provenance.verify_bundle(relocated, source; variant=:original)
    isequal(copied.snapshot, original.snapshot) || error("copied bundle provenance differs from the accepted bundle")
    _require_unchanged_inventory(inventory, relocated)
    expected_path = joinpath(records_directory, "original.records")
    baseline = isnothing(checkpoint) ? _fresh_original(config, expected_path) :
        _accepted_checkpoint(checkpoint, checkpoint_records, config, source, expected_path)
    expected = _read_records(expected_path)

    actual_path = joinpath(records_directory, "relocated-native.records")
    stderr_path = joinpath(records_directory, "relocated-native.stderr")
    command = Cmd(Cmd([copied.launcher, "emit", string(config.steps), string(config.copies),
        string(config.start_slot), String(config.outputs)]); dir=cwd)
    environment = copy(ENV)
    for name in UNSET_ENVIRONMENT
        delete!(environment, name)
    end
    environment["HOME"] = home
    environment["JULIA_DEPOT_PATH"] = external_depot
    command = setenv(command, environment)
    isempty(readdir(home)) && isempty(readdir(external_depot)) && isempty(readdir(cwd)) ||
        error("relocation HOME/depot/working directory was not initially empty")
    process = run(pipeline(ignorestatus(command); stdout=actual_path, stderr=stderr_path))
    success(process) || error("relocated native invocation failed; inspect $stderr_path")
    actual = _read_records(actual_path)
    isequal(actual.rows, expected.rows) || error("relocated full scientific records differ from the original ordinary baseline")
    isempty(readdir(external_depot)) || error("relocated native invocation populated the external depot")
    isempty(readdir(cwd)) || error("relocated native invocation wrote into its fresh working directory")
    isequal(Fixture.source_snapshot(), source) || error("loaded original scientific sources changed during qualification")
    Provenance.verify_unchanged(original, Fixture.source_snapshot(); variant=:original)
    Provenance.verify_unchanged(copied, Fixture.source_snapshot(); variant=:original)
    _require_unchanged_inventory(inventory, root)
    _require_unchanged_inventory(inventory, relocated)

    report_path = joinpath(scratch, "relocation.json")
    report = (format_version=1, scope=:same_host_bundle_relocation,
        same_host_only=true, host=(machine=Sys.MACHINE, kernel=Sys.KERNEL, julia=string(VERSION)),
        configuration=config, baseline, executor=:JuliaC_safe, build=original.metadata,
        original_bundle=root, relocated_bundle=relocated, scratch, report_path,
        scientific_source_sha256=source.aggregate_sha256,
        native_scientific_source_sha256=original.metadata["scientific_source_sha256"],
        pse_source_sha256=original.pse_dependency_source_sha256,
        artifact_inventory=(path=inventory_path, file_sha256=_file_sha256(inventory_path),
            aggregate_sha256=inventory.aggregate_sha256, files=inventory.files,
            symlinks=inventory.symlinks, directories=inventory.directories, bytes=inventory.bytes),
        provenance_and_artifacts_unchanged=true,
        record_count=actual.record_count, record_counts=actual.counts,
        exact_full_observation_parity=true, full_record_schema=RECORD_KINDS,
        expected_records=(path=expected_path, sha256=expected.records_file_sha256,
            sorted_records_sha256=expected.record_sha256),
        native_records=(path=actual_path, sha256=actual.records_file_sha256,
            sorted_records_sha256=actual.record_sha256), stderr_path,
        isolated_environment=(home, cwd, external_depot, external_depot_empty=true,
            working_directory_empty=true, home_entries_after=sort!(readdir(home)),
            unset_variables=UNSET_ENVIRONMENT, launcher_supplies_bundled_depot=true,
            bundled_depot=joinpath(relocated, "share", "julia")),
        authoring_sources_inaccessible_tested=false, system_library_portability_tested=false,
        runtime_rng_count=0, runtime_stochastic_coverage=false, timed=false)
    _write_json(report_path, report)
    return report
end

end # module DownstreamMAESPARelocation
