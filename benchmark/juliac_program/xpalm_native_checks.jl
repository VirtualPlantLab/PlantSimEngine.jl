module XPalmNativeChecks
using Test
using PlantSimEngine
import ..XPalmFixture as XF
const CASES = (
    (1,4,0,0,10,300.0,0.3,3.0),
    (4,8,0,0,1000,120.0,0.7,0.0),
    (0,4,2,1,500,200.0,0.4,10.0),
    (1,5,3,2,800,300.0,0.5,1.0),
    (0,3,0,0,40,300.0,0.3,3.0),
)
function reference(args)
    n,steps,birth_at,newborns,offset,initial_depth,root_rate,rain = args
    ids = collect(offset+1:offset+n)
    initial = XF.initial()
    forcing = XF.rows(steps;rain)
    model = CompositeModel((Object(id;kind=:soil,status=Status(initial)) for id in ids)...;
        applications=XF.specs(;initial_depth,root_rate),environment=XF._weather(forcing))
    simulation = PlantSimEngine.run!(model;steps=0,outputs=:all)
    for i in 1:steps
        if i == birth_at
            for j in 1:newborns
                id = offset+n+j
                register_object!(model,Object(id;kind=:soil,status=Status(initial)))
                push!(ids,id)
            end
        end
        PlantSimEngine.step!(simulation)
    end
    return XF.fingerprint(simulation,ids)
end
function native(exe,args;depot=nothing)
    command = Cmd([exe;"xpalm";collect(string.(args))])
    command = addenv(command,"JULIA_PROJECT"=>nothing,"JULIA_LOAD_PATH"=>nothing)
    isnothing(depot) || (command = addenv(command,"JULIA_DEPOT_PATH"=>depot))
    out = IOBuffer(); err = IOBuffer()
    process = run(pipeline(ignorestatus(command);stdout=out,stderr=err))
    success(process) || error("native XPalm exit $(process.exitcode): "*String(take!(err)))
    lines = split(chomp(String(take!(out))),'\n')
    header = parse.(Int,split(first(lines),','))
    length(header) == 2 && header[2] == args[2] || error("invalid native timestep count")
    length(lines) == header[1]+1 || error("invalid native row count")
    ids = Int[]
    states = NamedTuple[]
    for line in lines[2:end]
        fields = split(line,',')
        push!(ids,parse(Int,first(fields)))
        push!(states,NamedTuple{XF.STATE_VARIABLES}(Tuple(parse.(Float64,fields[2:end]))))
    end
    return (;ids,states)
end
function run_checks(bundle=readchomp(joinpath(@__DIR__,"build","latest.txt")))
    exe = joinpath(bundle,"bin","run-pse-program")
    native(exe,first(CASES)) # warm host-side parser/launcher, each child is fresh
    result = @testset "Safe JuliaC original XPalm" begin
        for args in CASES
            @test isequal(native(exe,args),reference(args))
        end
        moved = joinpath(mktempdir(),"bundle")
        cp(bundle,moved)
        @test isequal(native(joinpath(moved,"bin","run-pse-program"),CASES[3];depot=mktempdir()),reference(CASES[3]))
    end
    counts = Test.get_test_counts(result)
    return (passes=counts.passes+counts.cumulative_passes,
        fails=counts.fails+counts.cumulative_fails,errors=counts.errors+counts.cumulative_errors,
        cases=map(args -> (inputs=args,reference=reference(args),native=native(exe,args)),CASES),
        relocated_with_bundled_artifacts=true,variables=XF.STATE_VARIABLES)
end
end
