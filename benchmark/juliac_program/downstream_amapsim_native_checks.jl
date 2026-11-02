module DownstreamAMAPSimNativeChecks
include("downstream_amapsim_checks.jl")
const C=DownstreamAMAPSimChecks
const F=C.OF
const PSE=C.PSE
const OP=C.OP
include("downstream_amapsim_native_codec.jl")
include("downstream_amapsim_native_support.jl")
function check_native(launcher; nplants=1,steps=2,increment=.5,seed=1,outputs=:all,profile=:branch46)
    profile in (:branch46,:merisier) || throw(ArgumentError("unknown frozen native profile"))
    input=profile===:branch46 ? joinpath(F.ROOT,"test","fixtures","native_arena","branch46.fpa") :
        joinpath(F.ROOT,"test","fixtures","native_originals","merisier.fpa")
    cfg=F.config(;nplants,steps,increment,seed,outputs,input)
    fixture=F.construct(cfg);simulation=F.prepare_baseline(fixture,cfg)
    for _ in 1:steps;PSE.step!(simulation);end
    expected=IOBuffer();emit_ordinary(expected,simulation,fixture,cfg)
    mode=profile===:merisier ? "rngsnapshot" : "snapshot"
    actual=read(`$launcher $mode $nplants $steps $increment $seed $(outputs===:all)`)
    expected_bytes=take!(expected)
    @assert actual==expected_bytes "Native AMAP snapshot differs from ORIGINAL ordinary PSE"
    F.verify_sources(cfg)
    return (plants=nplants,steps,outputs,profile,bytes=length(actual),sha256=bytes2hex(F.sha256(actual)),work=F.work(simulation,fixture))
end
end
