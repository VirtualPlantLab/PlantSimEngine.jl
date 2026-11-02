module DownstreamAMAPSimMeasurements
include("downstream_amapsim_checks.jl")
const C=DownstreamAMAPSimChecks
const OF=C.OF;const TF=C.TF;const OP=C.OP;const PSE=C.PSE
include("downstream_amapsim_native_codec.jl")
include("downstream_amapsim_native_support.jl")

"""Ordinary typed-adapter control with the same precompiled native parameter
input and original native initializer as RegistryState. This host-only factory
uses public Object/CompositeModel constructors, never a changed scientific model.
Its setup boundary excludes FPA parsing/native parameter compilation in BOTH arms.
"""
function precompiled_fixture(authored)
    objects=map(PSE.model_objects(authored.model)) do object
        values=isnothing(object.status) ? NamedTuple() : NamedTuple(object.status)
        if hasproperty(values,:_native_pse_state)
            values=merge(values,(_native_pse_state=OP.clone_native_state(values._native_pse_state),))
        end
        PSE.Object(object.id;parent=object.parent,name=object.name,kind=object.kind,
            scale=object.scale,species=object.species,geometry=PSE.geometry(object),status=PSE.Status(values))
    end
    model=PSE.CompositeModel(objects...;applications=authored.applications)
    return merge(authored,(model=model,))
end
_timing(t)=(seconds=t.time,bytes=t.bytes,gctime=t.gctime)
function _baseline(F,cfg)
    GC.gc()
    construction=@timed F.construct(cfg)
    preparation=@timed F.prepare_baseline(construction.value,cfg)
    execution=@timed begin
        for _ in 1:cfg.steps;PSE.step!(preparation.value);end
    end
    return (construction=_timing(construction),preparation=_timing(preparation),execution=_timing(execution),
        fingerprint=F.fingerprint(preparation.value,construction.value),work=F.work(preparation.value,construction.value))
end
function _candidate(authored,programme,cfg)
    GC.gc()
    instantiation=@timed OP.instantiate(programme;retain=cfg.outputs===:all)
    state=instantiation.value
    fixture=merge(authored,(model=state,))
    execution=@timed OP.run!(state;steps=cfg.steps)
    return (instantiation=_timing(instantiation),execution=_timing(execution),
        fingerprint=TF.fingerprint(state,fixture),work=TF.work(state,fixture),
        lifetime_counter_entries=state.qualification_entries,registrations=state.registered_count,
        removals=state.removed_count,geometry_updates=state.geometry_updates)
end
function _precompiled_control(authored,cfg)
    GC.gc()
    construction=@timed precompiled_fixture(authored)
    preparation=@timed TF.prepare_baseline(construction.value,cfg)
    execution=@timed begin
        for _ in 1:cfg.steps;PSE.step!(preparation.value);end
    end
    return (construction=_timing(construction),preparation=_timing(preparation),execution=_timing(execution),
        fingerprint=TF.fingerprint(preparation.value,construction.value),work=TF.work(preparation.value,construction.value))
end
"""Warm three-arm runtime comparison plus explicit setup boundaries. Run one
untimed warmup first. Every sample starts fresh and checks full state/RNG/history
parity; original ordinary remains the PRIMARY baseline. The additional ordinary
precompiled-input control makes native authoring precomputation visible.
"""
function _configs(profile,nplants,steps,outputs,increment,seed)
    profile in (:branch46,:merisier) || throw(ArgumentError("unknown frozen profile"))
    folder=profile===:branch46 ? "native_arena" : "native_originals"
    file=profile===:branch46 ? "branch46.fpa" : "merisier.fpa"
    return (OF.config(;nplants,steps,outputs,increment,seed,input=joinpath(OF.ROOT,"test","fixtures",folder,file)),
        TF.config(;nplants,steps,outputs,increment,seed,input=joinpath(TF.ROOT,"test","fixtures",folder,file)))
end
function measure_case(;nplants=4,steps=2,outputs=:none,increment=.5,seed=1,samples=3,profile=:branch46)
    oc,tc=_configs(profile,nplants,steps,outputs,increment,seed)
    authoring=@timed TF.construct(tc)
    planning=@timed OP.prepare(authoring.value.model;constants=authoring.value.constants)
    results=NamedTuple[]
    for sample in 0:samples
        original=_baseline(OF,oc);typed=_baseline(TF,tc)
        control=_precompiled_control(authoring.value,tc)
        candidate=_candidate(authoring.value,planning.value,tc)
        @assert original.fingerprint==typed.fingerprint==control.fingerprint==candidate.fingerprint
        @assert original.work==typed.work==control.work==candidate.work
        sample>0 && push!(results,(original_ordinary=original,typed_ordinary=typed,
            typed_precompiled_ordinary=control,typed_compiled=candidate))
    end
    OF.verify_sources(oc);TF.verify_sources(tc)
    return (config=tc,authoring=_timing(authoring),planning=_timing(planning),samples=results,
        boundary=:fresh_prepared_state_run_only,
        scope=:native_architecture_geometry_internode_projection_with_identical_probe_and_counter,
        baseline=:ordinary_original_adapter,
        controls=(:ordinary_typed_adapter,:ordinary_typed_precompiled_input),
        construction_note="original/typed construction includes FPA and native parameter compilation; candidate and precompiled ordinary construction use the same original initializer and precompiled tables")
end
"""AOT runtime timings exclude setup, process startup and binary snapshot I/O.
The final AOT snapshot must match an ORIGINAL ordinary PSE state byte for byte.
"""
function measure_native_case(launcher; nplants=4,steps=8,outputs=:none,increment=.5,seed=1,
                             samples=3,profile=:branch46)
    samples>0 || throw(ArgumentError("positive measured repetition count required"))
    jit=measure_case(;nplants,steps,outputs,increment,seed,samples,profile)
    oc,tc=_configs(profile,nplants,steps,outputs,increment,seed)
    fixture=OF.construct(oc);simulation=OF.prepare_baseline(fixture,oc)
    for _ in 1:steps;PSE.step!(simulation);end
    expected=IOBuffer();emit_ordinary(expected,simulation,fixture,oc);expected_bytes=take!(expected)
    mode=profile===:merisier ? "rngperf" : "perf"
    process=@timed read(`$launcher $mode $nplants $steps $increment $seed $(outputs===:all) $samples`)
    io=IOBuffer(process.value);trials=NamedTuple[]
    while !eof(io)
        line=readline(io)
        line=="B" && break
        fields=split(line,',');length(fields)==6 && fields[1]=="P" || error("invalid native timing record")
        trial=parse(Int,fields[2])
        trial>0 && push!(trials,(trial,instantiation_s=parse(UInt64,fields[3])*1e-9,
            execution_s=parse(UInt64,fields[4])*1e-9,internodes=parse(Int,fields[5]),
            lifetime_counter_entries=parse(Int,fields[6])))
    end
    actual=read(io)
    actual==expected_bytes || error("AOT state/RNG/history snapshot differs from ORIGINAL ordinary PSE")
    length(trials)==samples || error("missing native trials")
    OF.verify_sources(oc);TF.verify_sources(tc)
    return (profile,jit,native=(samples=trials,process_wall_s=process.time,
        snapshot_bytes=length(actual),snapshot_sha256=bytes2hex(OF.sha256(actual)),
        parity=:byte_exact_original_ordinary_PSE,work=OF.work(simulation,fixture)))
end

end
