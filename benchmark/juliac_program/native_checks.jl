module NativeProgramChecks
using Test
using PlantSimEngine
import ..NativeFixture as NF
import ..ReusableProgramChecks as Checks

const CASES = (
    (1,3,0,0,10,0.5,0.25,20.0),
    (0,3,2,2,100,0.75,0.125,10.0),
    (7,4,3,3,1000,0.25,0.5,12.0),
    (0,2,0,0,25,0.5,0.25,8.0),
    (32,8,4,7,500,0.625,0.375,16.0),
)
function ordinary_result(args)
    n,steps,birth_at,newborns,offset,efficiency,conversion,temperature = args
    rows = [(T=temperature+i,) for i in 1:steps]
    specs = NF.specs(; efficiency,conversion)
    ids = collect((offset+1):(offset+n))
    sim = Checks._ordinary_start(ids,rows,specs,(leaf_area=1.0,biomass=0.0))
    for i in 1:steps
        if i == birth_at
            for j in 1:newborns
                id = offset+n+j
                register_object!(runtime_model(sim),Object(id;kind=:leaf,
                    status=Status(leaf_area=1.0,biomass=0.0)))
                push!(ids,id)
            end
        end
        PlantSimEngine.step!(sim)
    end
    carbon = 0.0
    biomass = 0.0
    for id in ids
        status = final_state(sim,ObjectId(id))
        carbon += status.carbon
        biomass += status.biomass
    end
    return (length(ids),steps,carbon,biomass)
end
function native_result(exe,args; depot=nothing)
    cmd = Cmd([exe; collect(string.(args))])
    cmd = addenv(cmd,"JULIA_PROJECT"=>nothing,"JULIA_LOAD_PATH"=>nothing)
    isnothing(depot) || (cmd = addenv(cmd,"JULIA_DEPOT_PATH"=>depot))
    output = IOBuffer()
    errors = IOBuffer()
    process = run(pipeline(ignorestatus(cmd);stdout=output,stderr=errors))
    success(process) || error("native exit $(process.exitcode): " * String(take!(errors)))
    row = split(strip(String(take!(output))),',')
    length(row) == 4 || error("unexpected native output")
    return (parse(Int,row[1]),parse(Int,row[2]),parse(Float64,row[3]),parse(Float64,row[4]))
end
function run_checks(bundle=readchomp(joinpath(@__DIR__,"build","latest.txt")))
    exe = joinpath(bundle,"bin","run-pse-program")
    native_result(exe,first(CASES)) # warm the Julia-side launch/parser helper
    results = map(CASES) do args
        expected = ordinary_result(args)
        measurement = @timed native_result(exe,args)
        observed = measurement.value
        @test observed === expected
        (inputs=args,expected,observed,process_wall_s=measurement.time)
    end
    # Copy only the bundle and run with an empty Julia depot. No package sources
    # are copied. This is a same-host relocation check, not cross-platform proof.
    relocated = mktempdir()
    cp(bundle,joinpath(relocated,"bundle"))
    depot = mktempdir()
    moved_exe = joinpath(relocated,"bundle","bin","run-pse-program")
    observed = native_result(moved_exe,CASES[2];depot)
    @test observed === results[2].expected
    for bad in ((-1,3,0,0,0,0.5,0.25,20.0),(0,3,0,2,0,0.5,0.25,20.0),(0,3,4,2,0,0.5,0.25,20.0))
        command = Cmd([exe; collect(string.(bad))])
        @test !success(pipeline(command;stdout=devnull,stderr=devnull))
    end
    return (cases=results,relocated_with_bundled_artifacts=observed,invalid_inputs_rejected=3,platform=Sys.MACHINE)
end
end
