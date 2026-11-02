module DownstreamMAESPABuildChecks
using Test, TOML

function _stage_calls!(calls,expression)
    expression isa Expr || return calls
    if expression.head===:function
        return _stage_calls!(calls,last(expression.args))
    end
    if expression.head===:call && first(expression.args)===:_maespa_build_stage
        push!(calls,expression)
    end
    foreach(item->_stage_calls!(calls,item),expression.args)
    return calls
end

"""Evaluate the actual build recipe's progress calls without compiling a model."""
function run_checks()
    path=joinpath(@__DIR__,"downstream_maespa_build.jl")
    source=read(path,String)
    first_index=findfirst("function _maespa_build_stage",source).start
    last_index=findfirst("function build_maespa_registry",source).start
    probe=Module(gensym(:MAESPABuildStageProbe))
    Core.eval(probe,:(using TOML))
    Base.include_string(probe,source[first_index:prevind(source,last_index)],path)
    calls=_stage_calls!(Expr[],Meta.parseall(source;filename=path))
    @testset "Actual MAESPA build progress calls" begin
        @test length(calls)==4
        mktempdir() do destination
            Core.eval(probe,quote
                destination=$destination
                entry="entry"; project="project"; profile=:daylight; source_root="source"
                image=(instantiated_project="project",)
                compilation_s=1.25; link_s=0.25; bundle_s=0.5
            end)
            for call in calls
                parameters=only(filter(item->item isa Expr && item.head===:parameters,call.args))
                details=only(filter(item->item isa Expr && item.head===:kw && item.args[1]===:details,parameters.args))
                @test Core.eval(probe,details.args[2]) isa NamedTuple
                Core.eval(probe,call)
                @test TOML.parsefile(joinpath(destination,"stage.toml"))["stage"]==String(Core.eval(probe,last(call.args)))
            end
        end
    end
    return (assertions=9,actual_recipe_calls=length(calls))
end

end
