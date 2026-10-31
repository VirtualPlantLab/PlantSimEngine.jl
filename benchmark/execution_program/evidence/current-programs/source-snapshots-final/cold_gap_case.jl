# One explicit new Kaimon Julia process/image per arm. This script never starts
# Julia. Set PSE_GAP_COLD_ARM before including, or pass an `arm` global Symbol.
# Kaimon's project import/startup has already happened and is not timed here.
let started=time_ns()
    include(joinpath(@__DIR__, "load_experiments.jl"))
    include(joinpath(@__DIR__, "lean_compiler.jl"))
    include(joinpath(@__DIR__, "direct_calls.jl"))
    include(joinpath(@__DIR__, "shared_call_program.jl"))
    include(joinpath(@__DIR__, "tight_call_program.jl"))
    include(joinpath(@__DIR__, "pure_julia_reference.jl"))
    include(joinpath(@__DIR__, "pure_julia_boundaries.jl"))
    include(joinpath(@__DIR__, "gap_benchmarks.jl"))
    include(joinpath(@__DIR__, "tight_gap_benchmarks.jl"))
    global cold_loader_seconds=(time_ns()-started)/1e9
end
cold_arm=isdefined(Main,:arm) ? arm : Symbol(get(ENV,"PSE_GAP_COLD_ARM","reference_executor"))
cold_arm in (:reference_executor,:tight_projected,:tight_union) || error("Unknown cold arm")
isdefined(Main,:cold_freshness) || error("Caller must attest to a fresh Kaimon process")
cold_freshness.new_process && cold_freshness.pid==Base.getpid() &&
    cold_freshness.pid!=cold_freshness.previous_pid || error("Distinct fresh PID required")
cold_spec=TightGapBenchmarks.register_tight_gap_case!(:cold_gap;nobjects=2,steps=2)
cold_record=M.measure_case(cold_spec,cold_arm;temperature=:first_use,
    freshness=cold_freshness,
    measure_retained=false)
cold_output=get(ENV,"PSE_GAP_COLD_OUTPUT",joinpath(@__DIR__,"results","pure-gap",
    "cold-$(cold_arm).json"))
open(cold_output,"w") do io
    PlantSimEngine.JSON.print(io,(loader_seconds=cold_loader_seconds,
        loader_scope=:experimental_loader_after_Kaimon_project_import,
        record=cold_record),2)
end
