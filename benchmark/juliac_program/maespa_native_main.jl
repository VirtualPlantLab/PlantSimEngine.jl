module MAESPAProgramApp

using PlantSimEngine
include("downstream_maespa_pse_sources.jl")
include("downstream_maespa_fixture.jl")
include(joinpath("app","src","registry_program.jl"))
const Fixture=DownstreamMAESPAFixture
const Registry=RegistryPrograms

let directory=get(ENV,"PSE_MAESPA_BUILD_DIR",nothing)
    if !isnothing(directory)
        mkpath(directory)
        write(joinpath(directory,"source_snapshot_sha256.txt"),Fixture.source_snapshot().aggregate_sha256*"\n")
        DownstreamMAESPAPSESources.write_snapshot(joinpath(directory,"pse_source_snapshot.json"))
    end
end

# Only authoring evaluates the public scientific builder and ordinary resolver.
# The constants retain the projected, independently owned graph, not fixtures or
# ordinary CompositeModel/Simulation/compiled execution objects.
const BUILD_PROFILE=get(ENV,"PSE_MAESPA_BUILD_PROFILE","daylight")
const SETTINGS=if BUILD_PROFILE=="daylight"
    ((copies=1,start_slot=13,outputs=:all),)
elseif BUILD_PROFILE=="matrix"
    Tuple((copies=copies,start_slot=start_slot,outputs=outputs)
        for copies in (1,4) for start_slot in (1,13) for outputs in (:none,:all))
else
    error("unadmitted MAESPA build profile")
end
let directory=get(ENV,"PSE_MAESPA_BUILD_DIR",nothing)
    if !isnothing(directory)
        record=(profile=BUILD_PROFILE,numeric_type="Float64",
            scope="complete_public_native_canopy_soil_non_tuzet",
            cases=[(copies=setting.copies,start_slot=setting.start_slot,outputs=String(setting.outputs)) for setting in SETTINGS])
        write(joinpath(directory,"native_cases.json"),Fixture.PSE.JSON.json(record))
    end
end
function _author_program(setting,index)
    fixture=Fixture.construct(Fixture.configuration(;steps=2,setting...))
    program=Registry.prepare(fixture.model;outputs=setting.outputs,constants=fixture.constants)
    isempty(Fixture.owned_seed_rngs(program.seed)) || error("native scientific RNG records are required for a scenario with runtime generators")
    directory=get(ENV,"PSE_MAESPA_BUILD_DIR",nothing)
    if !isnothing(directory)
        rows=Fixture.scientific_rngs(fixture.model,fixture)
        record=(configuration=(copies=setting.copies,start_slot=setting.start_slot,outputs=String(setting.outputs)),
            scope="construction_only",runtime_rng_count=0,
            runtime_stochastic_coverage=false,rngs=[(path=row.path,type=row.type,
                serialized_state_sha256=row.state_sha256,
                next_uint64_hex=[string(value;base=16,pad=16) for value in row.next_uint64]) for row in rows])
        write(joinpath(directory,"construction-rng-$index.json"),Fixture.PSE.JSON.json(record))
    end
    return program
end
const PROGRAMS=ntuple(index->_author_program(SETTINGS[index],index),length(SETTINGS))

function _run(program,steps,emit)
    state=Registry.instantiate(program)
    Registry.advance!(state,steps)
    if emit
        Registry.print_result(state)
    else
        print(Core.stdout,"MAESPA_DONE,",state.step,',',Registry._registry_object_count(state.objects),',',
            length(state.applications),',',length(state.groups),'\n')
    end
    return 0
end
function _measure_trial(program,steps,trial,final)
    GC.gc()
    started=time_ns()
    state=Registry.instantiate(program)
    instantiation_ns=time_ns()-started
    started=time_ns()
    Registry.advance!(state,steps)
    execution_ns=time_ns()-started
    print(Core.stdout,"P,",trial,',',instantiation_ns,',',execution_ns,'\n')
    if final
        print(Core.stdout,"B\n")
        Registry.print_result(state)
    end
    return nothing
end
function _dispatch(program,steps,mode,samples)
    if mode=="perf"
        for trial in 0:samples
            _measure_trial(program,steps,trial,trial==samples)
        end
        return 0
    end
    return _run(program,steps,mode=="emit")
end
@generated function _run_choice(index::Int,steps::Int,mode::String,samples::Int)
    branches=[:(index==$i && return _dispatch(getfield(PROGRAMS,$i),steps,mode,samples)) for i in 1:length(SETTINGS)]
    return Expr(:block,branches...,:(throw(ArgumentError("unknown MAESPA native case"))))
end
function main(arguments::Vector{String})
    length(arguments)>=1 || throw(ArgumentError("expected a MAESPA execution mode"))
    mode=arguments[1]
    mode in ("run","emit","perf") || throw(ArgumentError("expected run, emit or perf mode"))
    length(arguments)==(mode=="perf" ? 6 : 5) || throw(ArgumentError("expected mode steps copies start_slot none|all [samples]"))
    samples=mode=="perf" ? parse(Int,arguments[6]) : 0
    mode=="perf" && samples<1 && throw(ArgumentError("measured sample count must be positive"))
    steps=parse(Int,arguments[2]); copies=parse(Int,arguments[3]); start_slot=parse(Int,arguments[4])
    outputs=arguments[5]=="all" ? :all : arguments[5]=="none" ? :none : throw(ArgumentError("unknown retention mode"))
    0<=steps<=97-start_slot || throw(ArgumentError("duration exceeds the frozen scientific forcing"))
    selected=findfirst(setting->setting.copies==copies && setting.start_slot==start_slot && setting.outputs===outputs,SETTINGS)
    isnothing(selected) && throw(ArgumentError("admitted populations are one/four tiles and start slots one/thirteen"))
    return _run_choice(selected,steps,mode,samples)
end

end # module MAESPAProgramApp

function (@main)(arguments::Vector{String})
    return MAESPAProgramApp.main(arguments)
end
