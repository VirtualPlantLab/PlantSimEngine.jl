module DownstreamMAESPAOriginalScaling
using SHA
import ..DownstreamMAESPAFixture as Fixture
import ..DownstreamMAESPAMeasurements as Measurements
import ..DownstreamMAESPARegistry as Adapter
const PSE=Fixture.PSE
const EXPECTED_ROOT="/private/tmp/pse-juliac-large-20261102/sources/MAESPA"
const STAGES=Dict{Symbol,Any}()
_hash(path)=bytes2hex(sha256(read(path)))
_json_safe(value::Type)=string(value)
_json_safe(value::NamedTuple)=NamedTuple{keys(value)}(map(_json_safe,values(value)))
_json_safe(value::Tuple)=map(_json_safe,value)
_json_safe(value::AbstractArray)=map(_json_safe,value)
_json_safe(value::AbstractDict)=Dict(key=>_json_safe(item) for (key,item) in value)
_json_safe(value::AbstractFloat)=isfinite(value) ? value : (type=string(typeof(value)),special=string(value))
_json_safe(value)=value
function verify_original()
    source=Fixture.source_snapshot()
    realpath(source.root)==realpath(EXPECTED_ROOT) || error("ordinary baseline must use untouched frozen MAESPA")
    manifest=PSE.JSON.parsefile(joinpath(@__DIR__,"downstream_maespa_typing.json"))
    for row in source.files
        manifest["all_baseline_files"][row.path]==row.sha256 || error("original MAESPA source differs: $(row.path)")
    end
    return source
end
function construct_warmup(label::Symbol;copies=1,steps=24,start_slot=13,outputs=:all)
    verify_original()
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
function warm_records(label::Symbol;destination=joinpath(@__DIR__,"results","maespa_scaling","warmups"))
    value=STAGES[label]
    PSE.current_step(value.simulation)==value.config.steps || error("complete the requested warmup timeline first")
    records=Measurements._encoded_ordinary(value.simulation)
    mkpath(destination)
    path=joinpath(destination,"original-$(label).records")
    open(io->foreach(record->println(io,record),records),path,"w")
    count_h=count(line->occursin("String:1:H|",line),records)
    source=verify_original()
    report=(configuration=value.config,source_variant=:original,source_sha256=source.aggregate_sha256,
        records_path=path,record_count=length(records),record_sha256=bytes2hex(sha256(join(records,'\n'))),
        stream_key_records=count_h,work=Fixture.work_witness(value.simulation),timed=false,
        codec_sha256=_hash(joinpath(@__DIR__,"downstream_maespa_encoding.jl")),
        ordinary_adapter_sha256=_hash(joinpath(@__DIR__,"downstream_maespa_registry.jl")))
    write(joinpath(destination,"original-$(label).json"),PSE.JSON.json(_json_safe(report)))
    return (label,record_count=length(records),record_sha256=report.record_sha256,h_records=count_h)
end
function measure_case(;copies=1,steps=24,start_slot=13,outputs=:all,samples=3,
    destination=joinpath(@__DIR__,"results","maespa_scaling"),
    records_directory="/private/tmp/pse-juliac-large-20261102/maespa-original-records/final")
    verify_original()
    cfg=Fixture.configuration(;copies,steps,start_slot,outputs)
    name="original-$(copies)-$(steps)-$(start_slot)-$(outputs)"
    mkpath(destination)
    path=joinpath(destination,name*".json")
    ispath(path) && error("refuse to overwrite an accepted original checkpoint")
    mkpath(records_directory)
    records_path=joinpath(records_directory,name*".records")
    result=Measurements.measure_ordinary(;config=cfg,samples,variant=:original,records_path)
    report=(measurement=result,codec_sha256=_hash(joinpath(@__DIR__,"downstream_maespa_encoding.jl")),
        ordinary_adapter_sha256=_hash(joinpath(@__DIR__,"downstream_maespa_registry.jl")),
        measurements_sha256=_hash(joinpath(@__DIR__,"downstream_maespa_measurements.jl")),
        loaded_source_variant=:original,formatter_records=(:F,:T,:S,:H,:O,:E))
    write(path*".partial",PSE.JSON.json(_json_safe(report)));mv(path*".partial",path)
    return (name,path,record_sha256=first(result.samples).record_sha256,record_count=result.record_count,
        construction_s=[x.construction.seconds for x in result.samples],
        preparation_s=[x.preparation.seconds for x in result.samples],
        execution_s=[x.execution.seconds for x in result.samples],work=first(result.samples).work)
end
_median(values)=let x=sort!(collect(values)),n=length(values)
    isodd(n) ? x[(n+1)÷2] : (x[n÷2]+x[n÷2+1])/2
end
function measure_matrix(;samples=3,destination=joinpath(@__DIR__,"results","maespa_scaling"))
    reports=NamedTuple[]
    for copies in (1,4), (steps,start_slot) in ((24,13),(96,1)), outputs in (:all,:none)
        @info "Original MAESPA measured case" copies steps start_slot outputs
        value=measure_case(;copies,steps,start_slot,outputs,samples,destination)
        row=(name=value.name,configuration=(;copies,steps,start_slot,outputs,samples),
            objects=value.work.objects,applications=value.work.applications,
            construction_median_s=_median(value.construction_s),preparation_median_s=_median(value.preparation_s),
            execution_median_s=_median(value.execution_s),record_count=value.record_count,record_sha256=value.record_sha256,
            checkpoint=value.path)
        push!(reports,row)
        @info "Original MAESPA measured checkpoint saved" row
    end
    write(joinpath(destination,"original_summary.json"),PSE.JSON.json(_json_safe((format_version=1,
        source_variant=:untouched_original,source=verify_original(),samples,cases=reports))))
    return reports
end

end
