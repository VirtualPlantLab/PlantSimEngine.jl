module AMAPRegistryApp
include("app/src/object_program.jl")
module Frozen
const ObjectPrograms=parentmodule(@__MODULE__).ObjectPrograms
include("downstream_amapsim_fixture.jl")
Base.include(DownstreamAMAPSimFixture,joinpath(@__DIR__,"downstream_amapsim_bridge.jl"))
end
const F=Frozen.DownstreamAMAPSimFixture
const CONFIG=F.config(nplants=1,steps=1)
const AUTHORED=F.construct(CONFIG)
const PROGRAM=ObjectPrograms.prepare(AUTHORED.model;constants=AUTHORED.constants)
const RNG_CONFIG=F.config(nplants=1,steps=1,
    input=joinpath(F.ROOT,"test","fixtures","native_originals","merisier.fpa"))
const RNG_AUTHORED=F.construct(RNG_CONFIG)
const RNG_PROGRAM=ObjectPrograms.prepare(RNG_AUTHORED.model;constants=RNG_AUTHORED.constants)
include("downstream_amapsim_native_codec.jl")
function simulate(nplants::Int,steps::Int,increment::Float64,seed::UInt64,retain::Bool;stochastic=false)
    steps>=0 || throw(ArgumentError("negative steps"))
    state=ObjectPrograms.instantiate(stochastic ? RNG_PROGRAM : PROGRAM,nplants,increment,seed;retain)
    ObjectPrograms.run!(state;steps)
    return state
end
_print_fields(::Tuple{})=println(Core.stdout)
function _print_fields(fields::Tuple)
    print(Core.stdout,first(fields));rest=Base.tail(fields)
    isempty(rest) || print(Core.stdout,',')
    _print_fields(rest);nothing
end
function (@main)(args::Vector{String})
    if length(args)==7 && args[1] in ("perf","rngperf")
        n=parse(Int,args[2]);steps=parse(Int,args[3]);increment=parse(Float64,args[4]);seed=parse(UInt64,args[5]);retain=parse(Bool,args[6]);repeats=parse(Int,args[7])
        repeats>0 && steps>=0 || throw(ArgumentError("invalid performance repetition/step count"))
        for trial in 0:repeats
            GC.gc()
            start=time_ns();state=ObjectPrograms.instantiate(args[1]=="rngperf" ? RNG_PROGRAM : PROGRAM,n,increment,seed;retain);setup_ns=time_ns()-start
            start=time_ns();ObjectPrograms.run!(state;steps);run_ns=time_ns()-start
            _print_fields(("P",trial,setup_ns,run_ns,length(state.organ_lookup),state.qualification_entries))
            if trial==repeats
                println(Core.stdout,"B");emit_state(Core.stdout,state)
            end
        end
        return 0
    end
    length(args)==6 || throw(ArgumentError("mode plants steps increment seed retain"))
    mode=args[1]
    state=simulate(parse(Int,args[2]),parse(Int,args[3]),parse(Float64,args[4]),parse(UInt64,args[5]),parse(Bool,args[6]);stochastic=mode in ("rngsnapshot","rngrun"))
    if mode in ("snapshot","rngsnapshot")
        emit_state(Core.stdout,state)
    elseif mode in ("run","rngrun")
        _print_fields((length(state.organ_lookup),state.step,state.qualification_entries))
    else
        throw(ArgumentError("unknown AMAP mode"))
    end
    return 0
end
end
