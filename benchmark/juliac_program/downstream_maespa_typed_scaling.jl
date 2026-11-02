module DownstreamMAESPATypedScaling
using SHA
import ..DownstreamMAESPAFixture as Fixture
import ..DownstreamMAESPAMeasurements as Measurements
import ..DownstreamMAESPARegistry as Adapter
const PSE=Fixture.PSE
const EXPECTED_ROOT="/private/tmp/pse-juliac-large-20261102/typed-sources/MAESPA"
const EXPECTED_SOURCE_SHA="2134bb3606ebd31e97948d24d09dce3619d941a0105ce6bb9d478a3846205163"
const EXPECTED_TYPING_MANIFEST_SHA="4ee036133e8208f22b4d22e30714c96864c0b0aa77fbd3201791c4adafb1b0b5"
const LOADED_SOURCE_IMAGE=Fixture.source_snapshot()
const ORIGINAL_RECORDS_DIRECTORY="/private/tmp/pse-juliac-large-20261102/maespa-original-records/final-canonical"
const ORIGINAL_CHECKPOINT_DIRECTORY=joinpath(@__DIR__,"results","maespa_scaling","canonical","warmup_original")
const EXPECTED_ORIGINAL_SOURCE_SHA="21b3dd24a9a872cbf2a3254016cab687bc9397a1d97edb97b24f1b9a3eebf50f"
const STAGES=Dict{Symbol,Any}()
_hash(path)=bytes2hex(sha256(read(path)))
_json_safe(value::Type)=string(value)
_json_safe(value::NamedTuple)=NamedTuple{keys(value)}(map(_json_safe,values(value)))
_json_safe(value::Tuple)=map(_json_safe,value)
_json_safe(value::AbstractArray)=map(_json_safe,value)
_json_safe(value::AbstractDict)=Dict(key=>_json_safe(item) for (key,item) in value)
_json_safe(value::AbstractFloat)=isfinite(value) ? value : (type=string(typeof(value)),special=string(value))
_json_safe(value)=value
function verify_typed()
    source=Fixture.source_snapshot()
    isequal(source,LOADED_SOURCE_IMAGE) || error("MAESPA source changed since control helper was loaded")
    source.aggregate_sha256==EXPECTED_SOURCE_SHA || error("typed scientific source image changed after pinning")
    _hash(joinpath(@__DIR__,"downstream_maespa_typing.json"))==EXPECTED_TYPING_MANIFEST_SHA || error("typed source manifest changed after pinning")
    realpath(source.root)==realpath(EXPECTED_ROOT) || error("ordinary baseline must use pinned inference-typed MAESPA")
    manifest=PSE.JSON.parsefile(joinpath(@__DIR__,"downstream_maespa_typing.json"))
    for row in source.files
        manifest["all_typed_files"][row.path]==row.sha256 || error("inference-typed MAESPA source differs: $(row.path)")
    end
    return source
end
function construct_warmup(label::Symbol;copies=1,steps=24,start_slot=13,outputs=:all)
    verify_typed()
    cfg=Fixture.configuration(;copies,steps,start_slot,outputs)
    fixture=Fixture.construct(cfg)
    STAGES[label]=(config=cfg,fixture=fixture,simulation=nothing)
    return (phase=:constructed,label,copies,steps,start_slot,outputs,
        objects=length(PSE.object_ids(fixture.model)),applications=length(fixture.model.applications))
end
function prepare_warmup(label::Symbol)
    value=STAGES[label]
    simulation=Fixture.ordinary_start(value.fixture)
    STAGES[label]=merge(value,(simulation=simulation,))
    return (phase=:prepared,label,step=PSE.current_step(simulation),
        objects=length(PSE.object_ids(simulation.model)),applications=length(simulation.model.applications))
end
function advance_warmup(label::Symbol;steps=1)
    value=STAGES[label];simulation=value.simulation
    isnothing(simulation) && error("prepare the warmup before advancing")
    remaining=value.config.steps-PSE.current_step(simulation)
    count=min(steps,remaining)
    count>=0 || error("warmup exceeded its requested timeline")
    Fixture.ordinary_advance!(simulation,count)
    work=Fixture.work_witness(simulation)
    return (phase=:advanced,label,step=work.step,objects=work.objects,applications=work.applications,
        active=work.active,accepted=work.accepted,trials=work.trials,
        nonzero_assimilation=work.nonzero_assimilation,soil_available=work.soil_available)
end
function _original_checkpoint(config)
    name="original-$(config.copies)-$(config.steps)-$(config.start_slot)-$(config.outputs).json"
    checkpoint=PSE.JSON.parsefile(joinpath(ORIGINAL_CHECKPOINT_DIRECTORY,name))
    checkpoint["source_variant"]=="original" || error("ordinary original control required")
    checkpoint["source"]["aggregate_sha256"]==EXPECTED_ORIGINAL_SOURCE_SHA || error("original scientific source image changed")
    checkpoint["codec_sha256"]==_hash(joinpath(@__DIR__,"downstream_maespa_encoding.jl")) || error("original control uses a different observation codec")
    checkpoint["previous_snapshot_unchanged"] || error("canonical observation refresh changed its scientific snapshot")
    return checkpoint
end
function verify_original_records(records_path,config)
    name="original-$(config.copies)-$(config.steps)-$(config.start_slot)-$(config.outputs).records"
    original_path=joinpath(ORIGINAL_RECORDS_DIRECTORY,name)
    checkpoint=_original_checkpoint(config)
    expected=readlines(original_path);actual=readlines(records_path)
    expected_sha=bytes2hex(sha256(join(expected,'\n')))
    expected_sha==checkpoint["record_sha256"] || error("canonical original records changed after qualification")
    isequal(actual,expected) || error("inference-typed records differ from untouched-source ordinary PSE")
    return (original_records_path=original_path,original_records_sha256=expected_sha,
        exact_original_comparison=true,observation_codec_sha256=checkpoint["codec_sha256"])
end
function verify_original_snapshots(hashes,config)
    expected=_original_checkpoint(config)["snapshot_sha256"]
    !isempty(hashes) && all(==(expected),hashes) ||
        error("complete scientific snapshot, including RNGs, differs from untouched-source ordinary PSE")
    return (original_snapshot_sha256=expected,exact_original_complete_snapshot_including_rng=true)
end
function warm_records(label::Symbol;destination="/private/tmp/pse-juliac-large-20261102/maespa-typed-records/warmups-canonical")
    value=STAGES[label]
    PSE.current_step(value.simulation)==value.config.steps || error("complete the requested warmup timeline first")
    records=Measurements._encoded_ordinary(value.simulation)
    mkpath(destination)
    path=joinpath(destination,"typed-$(label).records")
    open(io->foreach(record->println(io,record),records),path,"w")
    h_prefix=Adapter.Registry.RegistryEncoding.record_prefix("H")
    count_h=count(line->startswith(line,h_prefix),records)
    comparison=verify_original_records(path,value.config)
    source=verify_typed()
    report=(comparison=comparison,configuration=value.config,source_variant=:typed,source_sha256=source.aggregate_sha256,
        records_path=path,record_count=length(records),record_sha256=bytes2hex(sha256(join(records,'\n'))),
        stream_key_records=count_h,work=Fixture.work_witness(value.simulation),timed=false,
        codec_sha256=_hash(joinpath(@__DIR__,"downstream_maespa_encoding.jl")),
        ordinary_adapter_sha256=_hash(joinpath(@__DIR__,"downstream_maespa_registry.jl")))
    write(joinpath(destination,"typed-$(label).json"),PSE.JSON.json(_json_safe(report)))
    return (label,record_count=length(records),record_sha256=report.record_sha256,h_records=count_h)
end
function measure_case(;copies=1,steps=24,start_slot=13,outputs=:all,samples=3,
    destination=joinpath(@__DIR__,"results","maespa_scaling"),
    records_directory="/private/tmp/pse-juliac-large-20261102/maespa-typed-records/final-canonical")
    verify_typed()
    cfg=Fixture.configuration(;copies,steps,start_slot,outputs)
    name="typed-$(copies)-$(steps)-$(start_slot)-$(outputs)"
    mkpath(destination)
    path=joinpath(destination,name*".json")
    ispath(path) && error("refuse to overwrite an accepted typed checkpoint")
    mkpath(records_directory)
    records_path=joinpath(records_directory,name*".records")
    result=Measurements.measure_ordinary(;config=cfg,samples,variant=:typed,records_path)
    comparison=merge(verify_original_records(records_path,cfg),
        verify_original_snapshots(map(row->row.snapshot_sha256,result.samples),cfg))
    report=(comparison=comparison,measurement=result,codec_sha256=_hash(joinpath(@__DIR__,"downstream_maespa_encoding.jl")),
        ordinary_adapter_sha256=_hash(joinpath(@__DIR__,"downstream_maespa_registry.jl")),
        measurements_sha256=_hash(joinpath(@__DIR__,"downstream_maespa_measurements.jl")),
        loaded_source_variant=:typed,formatter_records=(:F,:T,:S,:H,:O,:E))
    write(path*".partial",PSE.JSON.json(_json_safe(report)));mv(path*".partial",path)
    return (name,path,record_sha256=first(result.samples).record_sha256,record_count=result.record_count,
        construction_s=[x.construction.seconds for x in result.samples],
        preparation_s=[x.preparation.seconds for x in result.samples],
        execution_s=[x.execution.seconds for x in result.samples],work=first(result.samples).work)
end
_median(values)=let x=sort!(collect(values)),n=length(values)
    isodd(n) ? x[(n+1)÷2] : (x[n÷2]+x[n÷2+1])/2
end
function measure_matrix(;samples=3,destination=joinpath(@__DIR__,"results","maespa_scaling","canonical"))
    reports=NamedTuple[]
    for copies in (1,4), (steps,start_slot) in ((24,13),(96,1)), outputs in (:all,:none)
        @info "Inference-typed MAESPA measured case" copies steps start_slot outputs
        value=measure_case(;copies,steps,start_slot,outputs,samples,destination)
        row=(name=value.name,configuration=(;copies,steps,start_slot,outputs,samples),
            objects=value.work.objects,applications=value.work.applications,
            construction_median_s=_median(value.construction_s),preparation_median_s=_median(value.preparation_s),
            execution_median_s=_median(value.execution_s),record_count=value.record_count,record_sha256=value.record_sha256,
            checkpoint=value.path)
        push!(reports,row)
        @info "Inference-typed MAESPA measured checkpoint saved" row
    end
    write(joinpath(destination,"typed_summary.json"),PSE.JSON.json(_json_safe((format_version=1,
        source_variant=:inference_typed,source=verify_typed(),samples,cases=reports))))
    return reports
end

end
