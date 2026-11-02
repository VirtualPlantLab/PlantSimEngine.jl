module DownstreamMAESPAJITScaling
using SHA
import ..DownstreamMAESPATypedScaling as TypedControl
const Fixture=TypedControl.Fixture
const Measurements=TypedControl.Measurements
const Adapter=TypedControl.Adapter
const Registry=Measurements.Registry
const PSE=Fixture.PSE
const STAGES=Dict{Symbol,Any}()
function prepare_warmup(label::Symbol;copies=1,steps=24,start_slot=13,outputs=:all)
    TypedControl.verify_typed()
    config=Fixture.configuration(;copies,steps,start_slot,outputs)
    fixture=Fixture.construct(config)
    program=Registry.prepare(fixture.model;outputs=config.outputs,constants=fixture.constants)
    STAGES[label]=(config=config,fixture=fixture,program=program,state=nothing)
    return (phase=:prepared,label,copies,steps,start_slot,outputs,families=length(program.seed.groups),
        applications=length(program.seed.applications))
end
function instantiate_warmup(label::Symbol)
    value=STAGES[label];state=Registry.instantiate(value.program)
    STAGES[label]=merge(value,(state=state,))
    work=Adapter.witness(state)
    return (phase=:instantiated,label,step=work.step,objects=work.objects,applications=work.applications)
end
function advance_warmup(label::Symbol;steps=1)
    value=STAGES[label];state=value.state
    isnothing(state) && error("instantiate before advancing")
    remaining=value.config.steps-state.step
    Registry.advance!(state,min(steps,remaining))
    work=Adapter.witness(state)
    return (phase=:advanced,label,step=work.step,objects=work.objects,applications=work.applications,
        active=work.active,accepted=work.accepted,trials=work.trials,nonzero_assimilation=work.nonzero_assimilation)
end
function warm_records(label::Symbol;
    destination="/private/tmp/pse-juliac-large-20261102/maespa-jit-records/warmups-canonical")
    value=STAGES[label];value.state.step==value.config.steps || error("finish the requested warmup first")
    records=Measurements._encoded_candidate(value.state)
    mkpath(destination);path=joinpath(destination,"jit-$(label).records")
    open(io->foreach(record->println(io,record),records),path,"w")
    comparison=TypedControl.verify_original_records(path,value.config)
    return (label,comparison,record_count=length(records),record_sha256=bytes2hex(sha256(join(records,'\n'))),
        source_sha256=TypedControl.verify_typed().aggregate_sha256)
end
function measure_case(;copies=1,steps=24,start_slot=13,outputs=:all,samples=3,
    destination=joinpath(@__DIR__,"results","maespa_scaling","canonical"))
    TypedControl.verify_typed()
    config=Fixture.configuration(;copies,steps,start_slot,outputs)
    name="jit-$(copies)-$(steps)-$(start_slot)-$(outputs)";mkpath(destination)
    path=joinpath(destination,name*".json");ispath(path) && error("refuse to overwrite an accepted JIT checkpoint")
    records_path=joinpath("/private/tmp/pse-juliac-large-20261102/maespa-jit-records/final-canonical",name*".records")
    result=Measurements.measure_compiled(;config,samples,records_path)
    comparison=merge(TypedControl.verify_original_records(records_path,config),
        TypedControl.verify_original_snapshots(map(row->row.compiled.snapshot_sha256,result.samples),config))
    report=(measurement=result,comparison,source_variant=:inference_typed,
        measurement_driver_sha256=bytes2hex(sha256(read(joinpath(@__DIR__,"downstream_maespa_measurements.jl")))),
        raw_records_storage=:temporary_artifact_outside_repository)
    write(path*".partial",PSE.JSON.json(TypedControl._json_safe(report)));mv(path*".partial",path)
    return (name,path,objects=first(result.samples).compiled.work.objects,
        applications=first(result.samples).compiled.work.applications,
        construction_s=result.construction.seconds,planning_s=result.planning.seconds,
        instantiation_s=[x.compiled.instantiation.seconds for x in result.samples],
        execution_s=[x.compiled.execution.seconds for x in result.samples],
        paired_ordinary_construction_s=[x.ordinary.construction.seconds for x in result.samples],
        paired_ordinary_preparation_s=[x.ordinary.preparation.seconds for x in result.samples],
        paired_ordinary_s=[x.ordinary.execution.seconds for x in result.samples],
        record_count=result.record_count,record_sha256=comparison.original_records_sha256)
end

"""Checkpoint already-warmed paths; call only inside a coordinated quiet window.

The paired ordinary arm uses the same inference-typed sources. The independent
untouched-source ordinary records remain the exact scientific comparison.
Construction and planning are reported separately from repeated execution.
"""
function measure_matrix(;samples=3,destination=joinpath(@__DIR__,"results","maespa_scaling","canonical"))
    reports=NamedTuple[]
    median=TypedControl._median
    for copies in (1,4), (steps,start_slot) in ((24,13),(96,1)), outputs in (:all,:none)
        @info "Registry JIT MAESPA measured case" copies steps start_slot outputs
        value=measure_case(;copies,steps,start_slot,outputs,samples,destination)
        row=(name=value.name,configuration=(;copies,steps,start_slot,outputs,samples),
            objects=value.objects,applications=value.applications,
            authoring_construction_s=value.construction_s,authoring_planning_s=value.planning_s,
            instantiation_median_s=median(value.instantiation_s),execution_median_s=median(value.execution_s),
            paired_ordinary_construction_median_s=median(value.paired_ordinary_construction_s),
            paired_ordinary_preparation_median_s=median(value.paired_ordinary_preparation_s),
            paired_ordinary_execution_median_s=median(value.paired_ordinary_s),
            record_count=value.record_count,record_sha256=value.record_sha256,checkpoint=value.path)
        push!(reports,row)
        @info "Registry JIT MAESPA measured checkpoint saved" row
    end
    write(joinpath(destination,"jit_summary.json"),PSE.JSON.json(TypedControl._json_safe((format_version=1,
        executor=:registry_JIT,source_variant=:inference_typed,source=TypedControl.verify_typed(),samples,cases=reports))))
    return reports
end
end
