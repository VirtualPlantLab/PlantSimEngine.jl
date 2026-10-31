module PR243DispatchChecks

using Dates, Test, PlantSimEngine
const PSE=PlantSimEngine

export pr243_dispatch_probe, pr243_dispatch_checks, pr243_existing_status_view_checks

PSE.@process "pr243_dispatch_probe" verbose=false
struct DispatchProbeModel <: AbstractPr243_Dispatch_ProbeModel end
PSE.inputs_(::DispatchProbeModel)=NamedTuple()
PSE.outputs_(::DispatchProbeModel)=(value=1.0f0,kernel_calls=0)
PSE.environment_inputs_(::DispatchProbeModel)=(increment=0.0f0,)
function PSE.run!(::DispatchProbeModel,status,environment,constants,context)
    status.value+=environment.increment*oftype(status.value,context.time)
    status.kernel_calls+=1
    return nothing
end

# A genuine extension of the abstract batch protocol, with scientific work,
# sampling and publication delegated to its unchanged ordinary inner batch.
struct DelegatingBatch{B,C} <: PSE.AbstractExecutionBatch
    inner::B
    counts::C
end
function Base.getproperty(batch::DelegatingBatch,name::Symbol)
    name in (:inner,:counts) && return getfield(batch,name)
    return getproperty(getfield(batch,:inner),name)
end
Base.propertynames(batch::DelegatingBatch,private::Bool=false)=
    (:inner,:counts,propertynames(getfield(batch,:inner),private)...)

@noinline function PSE._run_model_execution_batch!(batch::DelegatingBatch,
    compiled,environment,time,constants,streams,retention)
    batch.counts.ordinary[]+=1
    return PSE._run_model_execution_batch!(batch.inner,compiled,environment,
        time,constants,streams,retention)
end
@noinline function PSE._run_model_execution_batch_profiled!(batch::DelegatingBatch,
    compiled,environment,time,constants,streams,retention,
    performance::PSE.RuntimePerformanceCounters)
    batch.counts.profiled[]+=1
    return PSE._run_model_execution_batch_profiled!(batch.inner,compiled,environment,
        time,constants,streams,retention,performance)
end

struct ProbePlanCompiler{C}
    counts::C
end
function (compiler::ProbePlanCompiler)(args...)
    ordinary=PSE.compile_model_execution_plan(args...)
    length(ordinary.batches)==length(ordinary.groups)==1 ||
        error("Dispatch probe requires exactly one ordinary batch/group")
    inner=only(ordinary.batches)
    inner isa PSE.CompiledExecutionBatch || error("Expected a genuine ordinary inner batch")
    original_group=only(ordinary.groups)
    only(original_group.batches)===inner || error("Ordinary group and plan disagree")
    batch=DelegatingBatch(inner,compiler.counts)
    batches=PSE.AbstractExecutionBatch[batch]
    groups=PSE.CompiledApplicationExecutionGroup[
        PSE.CompiledApplicationExecutionGroup(original_group.application,batches)]
    return PSE.CompiledExecutionPlan(groups,batches,
        PSE._execution_groups_by_application_slot(groups,
            length(ordinary.groups_by_application_slot)),
        ordinary.schedule,ordinary.model_revision,ordinary.environment_revision,
        ordinary.shared_target_plans)
end

_fixture()=PSE.CompositeModel(PSE.Object(:unit);
    applications=(PSE.ModelSpec(DispatchProbeModel();name=:probe,
        on=PSE.One(id=:unit),every=Hour(1)),),
    environment=(increment=2.0f0,duration=Hour(1)))
_snapshot(simulation)=(step=PSE.current_step(simulation),
    state=deepcopy(PSE.final_state(simulation,:unit)),
    history=Dict(key=>deepcopy(collect(stream))
        for (key,stream) in pairs(PSE.outputs(simulation))))

"""
Two steps, one object and one scientific model. On the pre-PR243 baseline the
group directly dispatches to the wrapper; on adapted PR243 it crosses the new
scheduled barrier first. Unadapted PR243 should raise MethodError here. Genuine
ordinary execution, environment sampling, publication and typed output history
must agree in both the ordinary and profiled modes.
"""
function pr243_dispatch_probe(;performance=false)
    counts=(ordinary=Ref(0),profiled=Ref(0))
    reference=PSE.run!(_fixture();steps=0,outputs=:all,performance)
    candidate=PSE.run!(_fixture();steps=0,outputs=:all,performance,
        _execution_plan_compiler=ProbePlanCompiler(counts))
    batch=only(candidate.execution_plan.batches)
    canonical=PSE.model_status(candidate.model,:unit)
    escaped=PSE.refvalue(canonical,:value)
    same_initial=isequal(_snapshot(candidate),_snapshot(reference))
    parity=Bool[]
    for _ in 1:2
        PSE.step!(reference);PSE.step!(candidate)
        push!(parity,isequal(_snapshot(candidate),_snapshot(reference)))
    end
    left=PSE.Advanced.runtime_performance(reference)
    right=PSE.Advanced.runtime_performance(candidate)
    selected=(:steps_executed,:execution_batches_visited,:execution_targets_visited)
    performance_counts=performance ?
        (reference=Dict(key=>get(left.counts,key,0) for key in selected),
         candidate=Dict(key=>get(right.counts,key,0) for key in selected)) : nothing
    return (;performance,scheduled_barrier=isdefined(PSE,:_run_scheduled_model_execution_batch!),
        same_initial,parity,ordinary_calls=counts.ordinary[],profiled_calls=counts.profiled[],
        genuine_inner=batch isa DelegatingBatch && batch.inner isa PSE.CompiledExecutionBatch,
        same_group_batch=only(only(candidate.execution_plan.groups).batches)===batch,
        live_canonical=PSE.model_status(candidate.model,:unit)===canonical &&
            PSE.refvalue(canonical,:value)===escaped,
        state=PSE.final_state(candidate,:unit),
        history=collect(PSE.outputs(candidate)[(:probe,PSE.ObjectId(:unit),:value)]),
        performance_counts,source=Base.pathof(PSE),julia=string(VERSION))
end

function pr243_dispatch_checks()
    reports=Any[]
    @testset "Abstract batch dispatch delegates genuine ordinary and profiled execution" begin
        for performance in (false,true)
            result=pr243_dispatch_probe(;performance)
            @test result.same_initial
            @test all(result.parity)
            @test result.genuine_inner
            @test result.same_group_batch
            @test result.live_canonical
            @test result.state.value===7.0f0
            @test result.state.kernel_calls==2
            @test result.history==[(1.0,3.0f0),(2.0,7.0f0)]
            @test result.ordinary_calls==(performance ? 0 : 2)
            @test result.profiled_calls==(performance ? 2 : 0)
            if performance
                @test result.performance_counts.reference==result.performance_counts.candidate
                @test all(==(2),values(result.performance_counts.candidate))
            end
            push!(reports,result)
        end
    end
    return (;passed=true,reports)
end

"""
Run exactly one complete unchanged upstream status-view lifecycle testset,
including its original identity/construction-counter assertions. Only the
imports/model definitions preceding that file's first testset are also loaded.
The fresh namespace avoids redefining Main's fixture types. This is a focused
testset result, never a whole-file pass. Kaimon supplies the external time limit.
"""
function pr243_existing_status_view_checks()
    path=joinpath(pkgdir(PSE),"test","test-model-output-destination-declarations.jl")
    label="empty and lifecycle-refreshed output destinations"
    parsed=Base.Meta.parseall(read(path,String);filename=path)
    istestset(expression)=expression isa Expr && expression.head===:macrocall &&
        expression.args[1]===Symbol("@testset")
    testsets=Expr[expression for expression in parsed.args if istestset(expression)]
    selected=only(expression for expression in testsets if expression.args[3]==label)
    first_test=findfirst(istestset,parsed.args)
    isnothing(first_test) && error("Upstream file has no top-level testset")
    namespace=Module(gensym(:PR243FocusedStatusView))
    Core.eval(namespace,:(using Dates))
    for expression in parsed.args[1:first_test-1]
        Core.eval(namespace,expression)
    end
    recorded=Ref{Any}(nothing)
    try
        @testset "Unchanged focused status-view lifecycle testset" begin
            recorded[]=Test.get_testset()
            Core.eval(namespace,selected)
        end
    catch err
        err isa Test.TestSetException || rethrow()
    end
    counts=Test.get_test_counts(recorded[])
    passes=counts.passes+counts.cumulative_passes
    failures=counts.fails+counts.cumulative_fails
    errors=counts.errors+counts.cumulative_errors
    return (;passed=iszero(failures+errors),passes,failures,errors,
        source=path,testsets=(label,),whole_file=false)
end

end
