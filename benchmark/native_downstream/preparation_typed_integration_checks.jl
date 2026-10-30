module PreparationTypedIntegrationChecks

using PlantSimEngine, Test
const PSE=PlantSimEngine
const PB=Main.NativePBDriver
const CR=Main.CompiledRegionsExperiment
const Tight=Main.TightCallProgram
const Reuse=Main.PlanViewReuse
const Bounded=Main.BoundedPreparation
const M=Main.NativeDownstreamMeasurements

export typed_boundary_arm_probe, preparation_typed_integration_checks
const _ARMS=(:reference_executor,:tight_only,:combined_prep_only,:combined_prep_tight)
_uses_preparation(arm)=arm in (:combined_prep_only,:combined_prep_tight)
_uses_tight(arm)=arm in (:tight_only,:combined_prep_tight)

# This is diagnostic/correctness orchestration. Scientific methods, compiler
# settings and executor payloads are untouched. Each dynamic boundary returns
# Any, keeping four large Simulation families out of the enclosing test frame.
Base.@nospecializeinfer @noinline function _stage(path,stage,arm,outputs,step=0)
    @nospecialize path
    if path!==nothing
        mkpath(dirname(path))
        open(path,"a") do io
            PSE.JSON.print(io,(stage=string(stage),arm=string(arm),
                outputs=string(outputs),step=step,pid=Base.getpid(),clock_ns=time_ns()))
            write(io,'\n');flush(io)
        end
    end
    stage in (:prepare_begin,:prepare_end,:arm_end) &&
        @info "Bounded typed integration" stage arm outputs step
    return nothing
end

Base.@nospecializeinfer @noinline function _construct(nobjects,steps)
    return Base.invokelatest(PB.pb_native_fixture;native=false,nobjects,steps).model
end
Base.@nospecializeinfer @noinline function _prepare_one(model,arm,outputs)
    @nospecialize model outputs
    model.status_storage===nothing || error("Ordinary canonical references required")
    if _uses_preparation(arm)
        Base.invokelatest(Reuse.enable_plan_view_reuse!,model)
        Base.invokelatest(Bounded.enable_bounded_preparation!,model)
    end
    if _uses_tight(arm)
        return Base.invokelatest(Tight.prepare_tight_calls,model;steps=0,outputs,
            state_strategy=:references,header_strategy=:projected,count_calls=true)
    end
    return Base.invokelatest(PSE.run!,model;steps=0,outputs)
end
Base.@nospecializeinfer @noinline function _advance(simulation)
    @nospecialize simulation
    Base.invokelatest(PSE.step!,simulation)
    return nothing
end
Base.@nospecializeinfer @noinline function _snapshot(simulation)
    @nospecialize simulation
    return Base.invokelatest(CR.portable_downstream_snapshot,simulation)
end
Base.@nospecializeinfer @noinline function _status_and_reference(simulation)
    @nospecialize simulation
    status=Base.invokelatest(PSE.model_status,simulation.model,1)
    reference=Base.invokelatest(PSE.refvalue,status,:Ra_SW_f)
    return (status=status,reference=reference)
end
Base.@nospecializeinfer @noinline function _references_stable(simulation,status,reference)
    @nospecialize simulation status reference
    current=Base.invokelatest(PSE.model_status,simulation.model,1)
    return current===status && Base.invokelatest(PSE.refvalue,current,:Ra_SW_f)===reference
end
Base.@nospecializeinfer @noinline function _mutate_reference(reference)
    @nospecialize reference
    reference[]+=oftype(reference[],1)
    return nothing
end
Base.@nospecializeinfer @noinline function _metadata(simulation,enabled)
    @nospecialize simulation
    reuse=Base.invokelatest(Reuse.plan_view_reuse_report,simulation.model)
    bounded=Base.invokelatest(Bounded.bounded_preparation_report,simulation.model)
    reused=reuse.recipe_hits+reuse.plain_preservations
    if enabled
        reused>0 || error("Enabled preparation saved no metadata operations")
        bounded.scene_entries>0 && bounded.scenario_plans>0 &&
            bounded.metadata_symbol_tables>0 || error("Bounded factories were not reached")
    else
        iszero(reused) && iszero(bounded.scene_entries) && iszero(bounded.scenario_plans) ||
            error("Preparation control was contaminated")
    end
    return (;reuse,bounded,reused_metadata_operations=reused)
end
Base.@nospecializeinfer @noinline function _typed_report(simulation)
    @nospecialize simulation
    return Base.invokelatest(Tight.tight_call_report,simulation)
end

"""Run just one tiny arm with persisted per-stage progress.

This probe does not claim ordinary equivalence by itself: its exact portable
snapshots can be compared with a separately executed ordinary arm. It retains
only snapshots/counters, never four inferred Simulation types in one container.
Use one arm first to distinguish preparation, execution and diagnostic stages.
"""
Base.@nospecializeinfer @noinline function typed_boundary_arm_probe(arm::Symbol;
    nobjects::Int=2,steps::Int=2,outputs=:none,progress_path=nothing)
    @nospecialize outputs progress_path
    arm in _ARMS || throw(ArgumentError("Unknown arm"))
    nobjects>=2 && steps>0 || throw(ArgumentError("Use at least 2 organs for positive reuse coverage"))
    Base.invokelatest(_stage,progress_path,:construct_begin,arm,outputs)
    model=Base.invokelatest(_construct,nobjects,steps)
    Base.invokelatest(_stage,progress_path,:construct_end,arm,outputs)
    Base.invokelatest(_stage,progress_path,:prepare_begin,arm,outputs)
    simulation=Base.invokelatest(_prepare_one,model,arm,outputs)
    Base.invokelatest(_stage,progress_path,:prepare_end,arm,outputs)
    saved=Base.invokelatest(_status_and_reference,simulation)
    snapshots=Any[Base.invokelatest(_snapshot,simulation)]
    identities=Bool[]
    for step in 1:steps
        Base.invokelatest(_stage,progress_path,:step_begin,arm,outputs,step)
        Base.invokelatest(_advance,simulation)
        Base.invokelatest(_stage,progress_path,:step_end,arm,outputs,step)
        push!(snapshots,Base.invokelatest(_snapshot,simulation))
        push!(identities,Base.invokelatest(_references_stable,
            simulation,saved.status,saved.reference))
        step<steps && Base.invokelatest(_mutate_reference,saved.reference)
    end
    Base.invokelatest(_stage,progress_path,:coverage_begin,arm,outputs)
    metadata=Base.invokelatest(_metadata,simulation,_uses_preparation(arm))
    typed=_uses_tight(arm) ? Base.invokelatest(_typed_report,simulation) : nothing
    digest=bytes2hex(M.SHA.sha256(repr(snapshots)))
    Base.invokelatest(_stage,progress_path,:arm_end,arm,outputs)
    return (;arm,outputs,nobjects,steps,snapshots,digest,identities,metadata,typed,
        interpretation=:bounded_check_orchestration_with_default_scientific_compilation)
end

"""Four independent tiny arms with explicit Any storage and dynamic test boundaries."""
function preparation_typed_integration_checks(;nobjects=2,steps=2,
    output_cases=(:none,:all),progress_path=nothing)
    reports=Any[]
    @testset "Bounded harness: metadata policies preserve typed original-kernel work" begin
        for outputs in output_cases
            results=Dict{Symbol,Any}()
            for arm in _ARMS
                results[arm]=Base.invokelatest(typed_boundary_arm_probe,arm;
                    nobjects,steps,outputs,progress_path)
            end
            ordinary=results[:reference_executor]
            for arm in _ARMS
                result=results[arm]
                @test result.digest==ordinary.digest
                @test isequal(result.snapshots,ordinary.snapshots)
                @test all(result.identities)
            end
            control=results[:tight_only].typed
            combined=results[:combined_prep_tight].typed
            for report in (control,combined)
                @test report.count_calls
                @test report.executed_numerical_roots==nobjects*steps
                @test report.executed_numerical_calls>0
                @test report.typed_model_lookups>0
                @test report.tight_batch_executions==steps
                @test report.fallback_batch_executions==0
                @test report.full_shared_numerical_roots==0
                @test report.full_shared_numerical_calls==0
                @test report.executed_native_column_fields==0
                @test report.lazy_public_wrappers==0
                @test report.constructed_rich_targets==0
            end
            @test combined.executed_numerical_calls==control.executed_numerical_calls
            @test combined.typed_model_lookups==control.typed_model_lookups
            @test combined.executed_numerical_fields==control.executed_numerical_fields
            for arm in _ARMS
                push!(reports,results[arm])
            end
        end
    end
    return (;passed=true,reports)
end

end # module
