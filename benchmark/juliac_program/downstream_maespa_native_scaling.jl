isdefined(@__MODULE__,:DownstreamMAESPAMeasurements) || include(joinpath(@__DIR__,"downstream_maespa_measurements.jl"))

module DownstreamMAESPANativeScaling
using SHA
import ..DownstreamMAESPAFixture as Fixture
import ..DownstreamMAESPAMeasurements as Measurements
const PSE=Fixture.PSE
const DESTINATION=joinpath(@__DIR__,"results","maespa_scaling","canonical")

_hash(path)=bytes2hex(sha256(read(path)))
_json_safe(value::Type)=string(value)
_json_safe(value::NamedTuple)=NamedTuple{keys(value)}(map(_json_safe,values(value)))
_json_safe(value::Tuple)=map(_json_safe,value)
_json_safe(value::AbstractArray)=map(_json_safe,value)
_json_safe(value::AbstractDict)=Dict(key=>_json_safe(item) for (key,item) in value)
_json_safe(value::AbstractFloat)=isfinite(value) ? value : (type=string(typeof(value)),special=string(value))
_json_safe(value)=value
function _save(path,record)
    write(path*".partial",PSE.JSON.json(_json_safe(record)))
    mv(path*".partial",path;force=true)
    return path
end
_median(values)=let data=sort!(collect(values)),n=length(data)
    isodd(n) ? data[(n+1)÷2] : (data[n÷2]+data[n÷2+1])/2
end

"""Pair the safe native runtime with freshly measured untouched-source PSE.
Only call in a serialized timing window after both complete paths are warm.
"""
function measure_case(bundle;copies=1,steps=24,start_slot=13,outputs=:all,samples=3,destination=DESTINATION)
    config=Fixture.configuration(;copies,steps,start_slot,outputs)
    name="$(copies)-$(steps)-$(start_slot)-$(outputs)"
    mkpath(destination)
    native_path=joinpath(destination,"native-original-"*name*".json")
    original_path=joinpath(destination,"original-"*name*".json")
    !ispath(native_path) && !ispath(original_path) || error("refuse to overwrite accepted timing checkpoints")
    control_path=joinpath(destination,"warmup_original","original-"*name*".json")
    control_sha=_hash(control_path)
    baseline=PSE.JSON.parsefile(control_path)
    baseline["source_variant"]=="original" && baseline["timed"]===false || error("expected an untouched original observation checkpoint")
    baseline["configuration"]==PSE.JSON.parse(PSE.JSON.json(_json_safe(config))) || error("original control has another scenario configuration")
    source=Fixture.source_snapshot()
    source.aggregate_sha256==baseline["source"]["aggregate_sha256"] || error("loaded scientific source differs from original control")
    codec_sha=_hash(joinpath(@__DIR__,"downstream_maespa_encoding.jl"))
    codec_sha==baseline["codec_sha256"] || error("original observations use another codec")
    records_path=baseline["records_path"]
    _hash(records_path)==baseline["records_file_sha256"] || error("original canonical records changed")
    gold=sort!(readlines(records_path))
    length(gold)==baseline["record_count"] && bytes2hex(sha256(join(gold,'\n')))==baseline["record_sha256"] ||
        error("original canonical record schema/hash differs from its control")
    gold=nothing
    result=Measurements.measure_native(bundle;config,samples,variant=:original)
    result.native.record_sha256==baseline["record_sha256"] || error("native records differ from canonical original checkpoint")
    for row in result.ordinary.samples
        row.record_sha256==baseline["record_sha256"] || error("fresh ordinary records changed")
        row.snapshot_sha256==baseline["snapshot_sha256"] || error("fresh original biological/RNG snapshot changed")
    end
    driver_sha=_hash(@__FILE__)
    measurement_sha=_hash(joinpath(@__DIR__,"downstream_maespa_measurements.jl"))
    ordinary=merge(result.ordinary,(records_path=records_path,))
    original_report=(measurement=ordinary,codec_sha256=codec_sha,
        ordinary_adapter_sha256=_hash(joinpath(@__DIR__,"downstream_maespa_registry.jl")),
        measurements_sha256=measurement_sha,driver_sha256=driver_sha,loaded_source_variant=:original,
        formatter_records=(:F,:T,:S,:H,:O,:E),records_file_sha256=baseline["records_file_sha256"],
        raw_records_storage=:temporary_artifact_outside_repository)
    report=(configuration=config,source_variant=:original,measurement=result,codec_sha256=codec_sha,
        measurements_sha256=measurement_sha,driver_sha256=driver_sha,
        canonical_control=control_path,canonical_control_sha256=control_sha,
        original_snapshot_unchanged=true,other_team_julia_jobs_paused=true)
    _hash(control_path)==control_sha && _hash(records_path)==baseline["records_file_sha256"] ||
        error("canonical original control changed during measurement")
    _save(native_path,report)
    _save(original_path,original_report)
    ordinary_s=_median(row.execution.seconds for row in result.ordinary.samples)
    native_s=_median(row.execution_s for row in result.native.samples)
    return (name,configuration=config,original_execution_median_s=ordinary_s,native_execution_median_s=native_s,
        speedup=ordinary_s/native_s,record_count=result.native.record_count,
        record_sha256=result.native.record_sha256,original_checkpoint=original_path,native_checkpoint=native_path)
end

function measure_matrix(bundle;samples=3,destination=DESTINATION)
    rows=NamedTuple[]
    for copies in (1,4),(steps,start_slot) in ((24,13),(96,1)),outputs in (:all,:none)
        @info "Paired original/native MAESPA timing" copies steps start_slot outputs
        result=measure_case(bundle;copies,steps,start_slot,outputs,samples,destination)
        push!(rows,result)
        _save(joinpath(destination,"native_original_summary.json"),(format_version=1,samples,
            timing_boundary=:warm_execution_setup_separate,status=length(rows)==8 ? :complete : :running,cases=rows))
    end
    return rows
end

end
