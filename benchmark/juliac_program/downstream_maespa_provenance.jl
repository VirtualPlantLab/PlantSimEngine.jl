module DownstreamMAESPAProvenance
using SHA, TOML
import PlantSimEngine
const JSON=PlantSimEngine.JSON
include("downstream_maespa_pse_sources.jl")
const PSESources=DownstreamMAESPAPSESources
const REQUIRED_ENTRIES=("maespa_native_main.jl","downstream_maespa_fixture.jl","downstream_maespa_encoding.jl",
    "app/src/registry_program.jl","app/src/registry_program_output.jl",
    "app/src/registry_program_display.jl",
    "app/src/object_program_maespa_environment.jl","app/src/typed_seed_copy.jl",
    "downstream_maespa_build.jl","downstream_maespa_pse_sources.jl","downstream_maespa_typing.py",
    "downstream_maespa_runtime_typing.py","downstream_maespa_closed_fields.py","downstream_maespa_leaf_outputs.py",
    "downstream_maespa_typing.json","downstream_maespa_typing.patch")

_hash(path)=bytes2hex(sha256(read(path)))
function _require_hash(path,expected)
    isfile(path) || error("missing native build artifact: $(basename(path))")
    actual=_hash(path)
    actual==expected || error("native build artifact changed: $(basename(path))")
    return actual
end

"""Bind native qualification to our successful safe/generic build artifacts.
The loaded ordinary control may use the original or typed scientific source;
both must match the explicitly archived typing manifest.
"""
function verify_bundle(bundle,source;variant::Symbol)
    variant in (:original,:typed) || throw(ArgumentError("source variant must be original or typed"))
    root=abspath(bundle)
    build_path=joinpath(root,"build.toml")
    isfile(build_path) || error("native qualification requires build.toml")
    metadata=TOML.parsefile(build_path)
    get(metadata,"format_version",nothing)==1 || error("unsupported native build metadata schema")
    get(metadata,"trim",nothing)=="safe" || error("native build was not recorded with safe trimming")
    get(metadata,"cpu",nothing)=="generic" || error("native build was not recorded for the generic CPU target")
    snapshot=Dict{String,String}("build.toml"=>_hash(build_path))
    checks=("bin/pse_program"=>"binary_sha256","bin/run-pse-program"=>"launcher_sha256",
        "entry_sources.toml"=>"entry_manifest_sha256","source-typing.json"=>"source_typing_sha256",
        "source-typing.patch"=>"source_patch_sha256","Project.toml"=>"project_sha256",
        "Manifest.toml"=>"manifest_sha256","construction_rngs.toml"=>"construction_manifest_sha256",
        "native_cases.json"=>"case_manifest_sha256",
        "pse_source_expected.json"=>"pse_source_expected_sha256",
        "pse_source_snapshot.json"=>"pse_source_snapshot_sha256")
    for (relative,key) in checks
        haskey(metadata,key) || error("native build metadata omits $key")
        snapshot[relative]=_require_hash(joinpath(root,relative),metadata[key])
    end
    entries=TOML.parsefile(joinpath(root,"entry_sources.toml"))
    all(name->haskey(entries,name),REQUIRED_ENTRIES) || error("native entry manifest omits a required source file")
    for (relative,hash) in entries
        snapshot[joinpath("entry_sources",relative)]=_require_hash(joinpath(root,"entry_sources",relative),hash)
        _require_hash(joinpath(@__DIR__,relative),hash)
    end
    typing=JSON.parse(read(joinpath(root,"source-typing.json"),String))
    typing["patch_sha256"]==metadata["source_patch_sha256"] || error("typing patch differs from its scientific manifest")
    typing["script_sha256"]==entries["downstream_maespa_typing.py"] || error("typing script differs from its scientific manifest")
    for (relative,hash) in typing["helper_script_sha256"]
        get(entries,relative,nothing)==hash || error("typing helper differs from its scientific manifest")
    end
    haskey(metadata,"pse_source_sha256") || error("native build omits its local PSE source identity")
    current_pse=PSESources.snapshot()
    for name in ("pse_source_expected.json","pse_source_snapshot.json")
        PSESources.verify_archived(joinpath(root,name);current=current_pse,
            expected_aggregate=metadata["pse_source_sha256"])
    end
    cases=JSON.parse(read(joinpath(root,"native_cases.json"),String))
    cases["profile"]==metadata["profile"] && cases["numeric_type"]=="Float64" || error("native case manifest differs from its build profile")
    cases["scope"]=="complete_public_native_canopy_soil_non_tuzet" || error("native build has another scientific scope")
    expected_cases=metadata["profile"]=="daylight" ? [(1,13,"all")] :
        metadata["profile"]=="matrix" ? [(copies,start,mode) for copies in (1,4) for start in (1,13) for mode in ("none","all")] :
        error("unknown native build profile")
    actual_cases=[(row["copies"],row["start_slot"],row["outputs"]) for row in cases["cases"]]
    actual_cases==expected_cases && metadata["case_count"]==length(expected_cases) || error("native case manifest omits or changes an admitted case")
    construction=TOML.parsefile(joinpath(root,"construction_rngs.toml"))
    length(construction)==length(expected_cases) || error("native build omits construction RNG provenance for a case")
    for (relative,hash) in construction
        snapshot[relative]=_require_hash(joinpath(root,relative),hash)
        record=JSON.parse(read(joinpath(root,relative),String))
        record["scope"]=="construction_only" && record["runtime_rng_count"]==0 &&
            record["runtime_stochastic_coverage"]===false || error("native RNG coverage does not match this deterministic scenario suite")
    end
    source_key=variant===:original ? "all_baseline_files" : "all_typed_files"
    root_key=variant===:original ? "baseline_root" : "typed_root"
    realpath(source.root)==realpath(typing[root_key]) || error("ordinary control loaded another scientific source variant")
    realpath(metadata["source_root"])==realpath(typing["typed_root"]) || error("native build loaded another scientific source root")
    for row in source.files
        get(typing[source_key],row.path,nothing)==row.sha256 || error("loaded scientific source differs from its archived manifest: $(row.path)")
    end
    # Both variants have identical paths. Hash the recorded typed scientific
    # subset in exactly the fixture's order, independently of loaded variant.
    typed_sha=bytes2hex(sha256(join((row.path*"\0"*typing["all_typed_files"][row.path]
        for row in source.files),"\n")))
    metadata["scientific_source_sha256"]==typed_sha || error("native scientific source inventory differs from the typing manifest")
    snapshot["source_snapshot_sha256.txt"]=_hash(joinpath(root,"source_snapshot_sha256.txt"))
    chomp(read(joinpath(root,"source_snapshot_sha256.txt"),String))==typed_sha || error("native authoring source snapshot changed")
    return (bundle=root,launcher=joinpath(root,"bin","run-pse-program"),metadata,snapshot,
        source_variant=variant,entry_hashes=entries,cases=actual_cases,loaded_scientific_source=source.aggregate_sha256,
        pse_dependency_source_sha256=current_pse.aggregate_sha256)
end

function require_case(provenance,configuration)
    (configuration.copies,configuration.start_slot,String(configuration.outputs)) in provenance.cases ||
        throw(ArgumentError("this scientific case is not included in the verified native build"))
    return nothing
end

function verify_unchanged(provenance,source;variant=provenance.source_variant)
    current=verify_bundle(provenance.bundle,source;variant)
    isequal(current.snapshot,provenance.snapshot) || error("native build artifacts changed during qualification")
    return current
end

end
