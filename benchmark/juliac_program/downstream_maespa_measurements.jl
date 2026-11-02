isdefined(@__MODULE__,:DownstreamMAESPARegistry) || include(joinpath(@__DIR__,"downstream_maespa_registry.jl"))
isdefined(@__MODULE__,:DownstreamMAESPAProvenance) || include(joinpath(@__DIR__,"downstream_maespa_provenance.jl"))

module DownstreamMAESPAMeasurements
using SHA, Serialization
import ..DownstreamMAESPAFixture as Fixture
import ..DownstreamMAESPARegistry as Adapter
import ..DownstreamMAESPAProvenance as Provenance
const Registry=Adapter.Registry

_timing(value)=(seconds=value.time,bytes=value.bytes,gctime=value.gctime)
function _snapshot_hash(snapshot)
    io=IOBuffer();serialize(io,snapshot)
    return bytes2hex(sha256(take!(io)))
end
function _encoded_ordinary(simulation)
    io=IOBuffer();Adapter.print_ordinary(simulation,io)
    return sort!(split(String(take!(io)),'\n';keepempty=false))
end
function _encoded_candidate(state)
    io=IOBuffer();Registry.print_result(state,io)
    return sort!(split(String(take!(io)),'\n';keepempty=false))
end
function _ordinary_trial(config)
    GC.gc()
    construction=@timed Fixture.construct(config)
    preparation=@timed Fixture.ordinary_start(construction.value)
    execution=@timed Fixture.ordinary_advance!(preparation.value,config.steps)
    snapshot=Fixture.ordinary_snapshot(preparation.value,construction.value)
    records=_encoded_ordinary(preparation.value)
    return (construction=_timing(construction),preparation=_timing(preparation),execution=_timing(execution),
        snapshot_sha256=_snapshot_hash(snapshot),record_sha256=bytes2hex(sha256(join(records,'\n'))),
        work=Fixture.work_witness(preparation.value)),records
end

"""Warm ordinary control; every sample constructs an independent public model.
Construction includes public scenario building/forcing/RNG setup. Preparation is
ordinary `run!(...;steps=0)`. Execution is the complete requested scientific
timeline. Hashing, observation formatting and source checks are outside timers.
"""
function measure_ordinary(;config=Fixture.configuration(),samples=3,records_path=nothing,variant)
    samples>=1 || throw(ArgumentError("positive measured sample count required"))
    before=Fixture.source_snapshot()
    rows=NamedTuple[]; expected=nothing
    for trial in 0:samples
        row,records=_ordinary_trial(config)
        isnothing(expected) ? (expected=records) : isequal(records,expected) || error("ordinary fresh-run observations changed")
        trial>0 && push!(rows,row)
    end
    if !isnothing(records_path)
        mkpath(dirname(abspath(records_path)))
        open(io->foreach(record->println(io,record),expected),records_path,"w")
    end
    isequal(Fixture.source_snapshot(),before) || error("scientific source files changed during measurement")
    return (configuration=config,executor=:ordinary_PSE,source_variant=variant,samples=rows,
        source=before,records_path,record_count=length(expected),
        timing_boundary=:construction_then_ordinary_preparation_then_complete_run,
        compilation=:one_untimed_warmup_excluded)
end

"""Reusable compiled runtime control with explicit one-time authoring cost.
Planning includes deepcopy, ordinary resolution, lowering and typed copy-schema
preparation. Each measured instance owns fresh numerical state and histories.
The same loaded-source ordinary PSE arm is always measured and compared.
"""
function measure_compiled(;config=Fixture.configuration(),samples=3,records_path=nothing)
    samples>=1 || throw(ArgumentError("positive measured sample count required"))
    before=Fixture.source_snapshot()
    construction=@timed Fixture.construct(config)
    planning=@timed Registry.prepare(construction.value.model;outputs=config.outputs,constants=construction.value.constants)
    rows=NamedTuple[]; expected=nothing
    for trial in 0:samples
        ordinary,records=_ordinary_trial(config)
        GC.gc()
        instantiation=@timed Registry.instantiate(planning.value)
        execution=@timed Registry.advance!(instantiation.value,config.steps)
        candidate_records=_encoded_candidate(instantiation.value)
        isequal(candidate_records,records) || error("complete compiled observations differ from ordinary PSE")
        snapshot=Adapter.snapshot(instantiation.value,construction.value)
        _snapshot_hash(snapshot)==ordinary.snapshot_sha256 || error("complete compiled status/RNG/history/backend snapshot differs")
        isnothing(expected) ? (expected=records) : isequal(records,expected) || error("fresh-run observations changed")
        trial>0 && push!(rows,(ordinary=ordinary,compiled=(instantiation=_timing(instantiation),execution=_timing(execution),
            snapshot_sha256=_snapshot_hash(snapshot),work=Adapter.witness(instantiation.value))))
    end
    if !isnothing(records_path)
        mkpath(dirname(abspath(records_path)))
        open(io->foreach(record->println(io,record),expected),records_path,"w")
    end
    isequal(Fixture.source_snapshot(),before) || error("scientific source files changed during measurement")
    return (configuration=config,baseline=:ordinary_PSE,construction=_timing(construction),planning=_timing(planning),
        samples=rows,source=before,records_path,record_count=length(expected),
        families=length(planning.value.seed.groups),applications=length(planning.value.seed.applications),
        timing_boundary=:reused_program_private_instantiation_then_complete_run,
        compilation=:one_untimed_warmup_excluded)
end

"""Native timing excludes startup and formatting; final full records must match
the independent ordinary control. Trial zero is internally timed and excluded
from measured summaries.
"""
function measure_native(bundle;config=Fixture.configuration(),samples=3,variant)
    config.T===Float64 || throw(ArgumentError("this native scenario suite was authored for Float64"))
    provenance=Provenance.verify_bundle(bundle,Fixture.source_snapshot();variant)
    Provenance.require_case(provenance,config)
    ordinary=measure_ordinary(;config,samples,variant)
    _,expected=_ordinary_trial(config)
    command=Cmd([provenance.launcher,"perf",string(config.steps),string(config.copies),
        string(config.start_slot),String(config.outputs),string(samples)])
    process=withenv("JULIA_NUM_THREADS"=>"2","JULIA_NUM_GC_THREADS"=>nothing) do
        @timed read(command,String)
    end
    lines=split(process.value,'\n';keepempty=false)
    marker=findfirst(==("B"),lines)
    isnothing(marker) && error("native timing did not emit its full observation boundary")
    all_trials=NamedTuple[]
    for line in lines[1:marker-1]
        fields=split(line,',')
        length(fields)==4 && fields[1]=="P" || error("invalid native timing record")
        trial=parse(Int,fields[2])
        push!(all_trials,(trial,instantiation_s=parse(UInt64,fields[3])*1e-9,
            execution_s=parse(UInt64,fields[4])*1e-9))
    end
    actual=sort!(lines[marker+1:end])
    isequal(actual,expected) || error("full native scientific records differ from ordinary PSE")
    [row.trial for row in all_trials]==collect(0:samples) || error("native trials must occur exactly once in 0:samples order")
    trials=all_trials[2:end]
    Provenance.verify_unchanged(provenance,Fixture.source_snapshot();variant)
    return (ordinary,native=(warmup=first(all_trials),samples=trials,process_wall_s=process.time,record_count=length(actual),
        record_sha256=bytes2hex(sha256(join(actual,'\n'))),parity=:exact_full_records,
        requested_runtime_environment=(julia_num_threads="2",julia_num_gc_threads=nothing,gc_thread_setting=:julia_default),
        build=provenance.metadata,timing_boundary=:private_instantiation_then_complete_run_startup_and_output_excluded))
end

end
