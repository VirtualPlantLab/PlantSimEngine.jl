module PhytomerNativeChecks
using Test,PlantSimEngine
import ..PhytomerFixture as PF
const CASES=((2,0.001,1.0,22.0,31.0,0),(4,0.05,1.0,22.0,31.0,0),
    (6,0.1,2.0,22.0,31.0,12),(8,0.15,0.5,25.0,30.0,3))
function reference(args)
    days,rate,biomass,Tmin,Tmax,initiation_age=args
    simulation=PF.ordinary(PF.rows(days;Tmin,Tmax);rate,biomass,initiation_age)
    return PF.fingerprint(PlantSimEngine.runtime_model(simulation))
end
_decode(token,example::ObjectId)=ObjectId(parse(Int,token))
_decode(token,example::Bool)=parse(Bool,token)
_decode(token,example::Int)=parse(Int,token)
_decode(token,example::Float64)=parse(Float64,token)
function native(exe,args,expected;depot=nothing)
    command=Cmd([exe;"phytomer";collect(string.(args))])
    isnothing(depot) || (command=addenv(command,"JULIA_DEPOT_PATH"=>depot))
    out=IOBuffer();err=IOBuffer()
    process=run(pipeline(ignorestatus(command);stdout=out,stderr=err))
    success(process) || error("native growth exit $(process.exitcode): "*String(take!(err)))
    lines=split(chomp(String(take!(out))),'\n'); header=parse.(Int,split(first(lines),','))
    @test header==[length(expected),args[1]]
    rows=NamedTuple[]
    for line in lines[2:end]
        fields=split(line,',');id=parse(Int,fields[2])
        example=only(filter(r->r.object_id==id,expected))
        values_=map((token,value)->_decode(token,value),Tuple(fields[6:end]),values(example.status))
        status=NamedTuple{keys(example.status)}(values_)
        parent=parse(Int,fields[3]);parent_id=parent==0 ? nothing : parent
        push!(rows,(object_id=id,parent_id,scale=Symbol(fields[1]),link=Symbol(fields[4]),index=parse(Int,fields[5]),status))
    end
    return sort!(rows;by=r->r.object_id)
end
function run_checks(bundle=readchomp(joinpath(@__DIR__,"build","latest.txt")))
    exe=joinpath(bundle,"bin","run-pse-program");evidence=NamedTuple[]
    result=@testset "Safe native original phytomer emission" begin
        for args in CASES
            expected=reference(args);observed=native(exe,args,expected)
            @test isequal(observed,expected)
            push!(evidence,(inputs=args,expected,observed))
        end
        moved=joinpath(mktempdir(),"bundle");cp(bundle,moved)
        expected=reference(CASES[3])
        @test isequal(native(joinpath(moved,"bin","run-pse-program"),CASES[3],expected;depot=mktempdir()),expected)
    end
    c=Test.get_test_counts(result)
    return (passes=c.passes+c.cumulative_passes,fails=c.fails+c.cumulative_fails,
        errors=c.errors+c.cumulative_errors,cases=evidence,relocated=true)
end
end
