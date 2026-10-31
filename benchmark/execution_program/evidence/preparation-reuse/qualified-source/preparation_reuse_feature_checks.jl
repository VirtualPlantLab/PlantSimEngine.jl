module PreparationReuseFeatureChecks

using Dates, Test, PlantSimEngine
const PSE=PlantSimEngine
const Harness=Main.PreparationReuseMeasurements
const Reuse=Main.PlanViewReuse
const Bounded=Main.BoundedPreparation

export preparation_initializer_feature_check, preparation_mixed_cadence_feature_check,
    preparation_distributed_feature_check, preparation_spatial_feature_check,
    preparation_feature_case

_newborn()=getfield(Main,:NewbornPreparationChecks)
_fresh_distributed()=getfield(Main,:NewbornFreshDistributedChecks)

function _reports(simulation,arm)
    arm in (:bounded_preparation,:combined) ||
        throw(ArgumentError("Select bounded_preparation or combined for these focused gates"))
    bounded=Bounded.bounded_preparation_report(simulation)
    reuse=Reuse.plan_view_reuse_report(simulation)
    @test bounded.scene_entries>0
    @test bounded.scenario_plans>0
    @test bounded.metadata_symbol_tables>0
    @test reuse.enabled===(arm===:combined)
    if arm===:combined
        @test reuse.recipe_view_assemblies+reuse.ordinary_compiler_calls>0
    end
    actual_reuse=reuse.recipe_hits+reuse.plain_preservations
    # A temporal/private-only fixture may intentionally use ordinary views.
    # Positive recipe work is independently required by the PB/factorial gates;
    # this feature gate reports the actual work without inventing eligibility.
    return (;bounded,reuse,actual_reuse,
        reuse_qualification=iszero(actual_reuse) ? :no_recipe_reuse_claim_in_this_fixture :
            :observed_metadata_recipe_or_plain_preservation_work,
        native_fields=0,driver_units=0,native_driver_units=0)
end

function _live_many_checks(simulation,key)
    bindings=get(simulation.compiled.input_bindings_by_target,key,())
    view=simulation.compiled.status_views_by_target[key]
    for binding in bindings
        binding.multiplicity===:many || continue
        bound=getproperty(view.bound_inputs,binding.input)
        @test collect(PSE.object_ids(bound))==binding.source_ids
        @test length(bound)==length(PSE.object_ids(bound))
        if binding.carrier_hint!==:temporal_stream
            @test bound.values===binding.carrier
            refs=parent(binding.carrier)
            for (index,id) in pairs(binding.source_ids)
                @test refs[index]===PSE.refvalue(
                    PSE.model_status(simulation.model,id),binding.source_var)
            end
        end
    end
    return nothing
end

"""
One small paired case from the existing trusted newborn fixture. It exercises
targeted initialization, two manual calls sampling a mutable environment in the
same step, live Many IDs/cells, PreviousTimeStep and normal continuation. The old
newborn-promotion optimization is disabled in both arms; only the requested
preparation policy is enabled. No benchmark or multi-case matrix runs here.
"""
function preparation_initializer_feature_check(;arm=:bounded_preparation,
    mutation=:none,source_every=Hour(1),steps=3,outputs=:all,edit_source=false)
    steps>0 || throw(ArgumentError("Run at least one step to exercise the feature"))
    edit_source && source_every!=Hour(2) && throw(ArgumentError(
        "The escaped source edit check uses the trusted Hour(2) fixture"))
    Checks=_newborn()
    left=Checks.preparation_fixture(;mutation,source_every)
    right=Checks.preparation_fixture(;mutation,source_every)
    reference=PSE.run!(left.model;steps=0,outputs)
    candidate=Harness.prepare_arm(right.model,arm;steps=0,outputs)
    escaped_left=PSE.refvalue(PSE.model_status(left.model,1),:supply)
    escaped_right=PSE.refvalue(PSE.model_status(right.model,1),:supply)
    @testset "Focused preparation initializer/environment/Many case" begin
        @test isequal(Checks._snapshot(candidate),Checks._snapshot(reference))
        for step in 1:steps
            PSE.step!(reference);PSE.step!(candidate)
            if edit_source && step==2
                escaped_left[]=41.0f0
                escaped_right[]=41.0f0
            end
            @test isequal(Checks._snapshot(candidate),Checks._snapshot(reference))
            @test PSE.refvalue(PSE.model_status(left.model,1),:supply)===escaped_left
            @test PSE.refvalue(PSE.model_status(right.model,1),:supply)===escaped_right
            creator=PSE.final_state(candidate,0)
            @test creator.second_sample===creator.first_sample+1.0f0
            @test creator.first_sample===Float32(9+min(step,2))
            @test right.weather.T===left.weather.T
            if source_every==Hour(2)
                @test PSE.model_status(candidate.model,1).source_runs==cld(step,2)
            end
            if edit_source
                @test escaped_right[]===(step==1 ? 8.0f0 : 40.0f0+Float32(cld(step,2)))
            end
            if step<=2
                @test creator.initialized===Float32(11+step)
                id=step+9
                newborn=PSE.final_state(candidate,id)
                @test newborn.initializer_runs>0
                @test PSE.ObjectId(id) in newborn.ids
                @test length(newborn.ids)==length(newborn.observed)
                @test newborn.total===sum(newborn.observed;init=0.0f0)
                _live_many_checks(candidate,(:probe,PSE.ObjectId(id)))
            end
        end
        report=_reports(candidate,arm)
        return (;passed=true,arm,mutation,source_every=string(source_every),steps,
            outputs,report,objects=length(PSE.object_ids(candidate.model)),
            oracle=:ordinary_per_step_full_state_history_topology_and_live_many_refs)
    end
end

"""One mixed Hour1/Hour2 case with an escaped source edit between steps."""
function preparation_mixed_cadence_feature_check(;arm=:bounded_preparation,outputs=:all)
    return preparation_initializer_feature_check(;arm,outputs,source_every=Hour(2),
        steps=4,edit_source=true)
end

"""The trusted late-owner fixture: a newborn's user-seeded from_status field
becomes distributed-owned at ordinary refresh, while the same scalar Ref stays
live. This tests preparation semantics without enabling binding promotion.
"""
function preparation_distributed_feature_check(;arm=:bounded_preparation,outputs=:all)
    Checks=_newborn()
    Fresh=_fresh_distributed()
    left,right=(cells=Any[],facts=Any[],),(cells=Any[],facts=Any[],)
    reference=PSE.run!(Fresh._fixture();steps=0,outputs,constants=left)
    candidate=Harness.prepare_arm(Fresh._fixture(),arm;steps=0,outputs,constants=right)
    @testset "Focused preparation late distributed ownership case" begin
        @test isequal(Checks._snapshot(candidate),Checks._snapshot(reference))
        for step in 1:2
            PSE.step!(reference);PSE.step!(candidate)
            @test isequal(Checks._snapshot(candidate),Checks._snapshot(reference))
            left_cell,right_cell=only(left.cells),only(right.cells)
            @test PSE.refvalue(PSE.model_status(reference.model,10),
                :distributed_signal)===left_cell
            @test PSE.refvalue(PSE.model_status(candidate.model,10),
                :distributed_signal)===right_cell
            @test right_cell[]===left_cell[]===(step==1 ? 3.0f0 : 7.0f0)
            @test Fresh._distributed_owners(candidate.compiled.distributed_outputs,10)==1
            _live_many_checks(candidate,(:probe,PSE.ObjectId(10)))
        end
        left_fact,right_fact=only(left.facts),only(right.facts)
        @test left_fact.owners_before==left_fact.owners_after==0
        @test right_fact.owners_before==right_fact.owners_after==0
        @test left_fact.observed===right_fact.observed===3.0f0
        report=_reports(candidate,arm)
        return (;passed=true,arm,outputs,report,
            oracle=:ordinary_full_history_late_writer_ownership_and_canonical_cell_identity)
    end
end

"""
One existing tiny spatial fixture from LeanNativeChecks._environment_fixture.
Load lean_checks.jl and its normal dependencies before this optional subcall.
It runs ordinary reference storage in both arms, with a slower model cadence,
then coalesces growth/movement and edits the mutable spatial backend. No new
model/backend definitions are copied into this file.
"""
function preparation_spatial_feature_check(;arm=:bounded_preparation,outputs=:all)
    isdefined(Main,:LeanNativeChecks) || error(
        "Load existing lean_checks.jl and its dependencies before the spatial subcall")
    LeanChecks=getfield(Main,:LeanNativeChecks)
    CR=getfield(Main,:CompiledRegionsExperiment)
    left=LeanChecks._environment_fixture(false;spatial=true)
    right=LeanChecks._environment_fixture(false;spatial=true)
    reference=PSE.run!(left.model;steps=0,outputs)
    candidate=Harness.prepare_arm(right.model,arm;steps=0,outputs)
    escaped=PSE.refvalue(PSE.model_status(right.model,1),:signal)
    @testset "Focused preparation mutable spatial environment and handle refresh" begin
        for _ in 1:4
            PSE.step!(reference);PSE.step!(candidate)
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
        end
        @test escaped[]===12.0f0
        @test PSE.model_status(candidate.model,1).visits==2
        for fixture in (left,right)
            PSE.register_object!(fixture.model,PSE.Object(3;
                kind=:probe,geometry=(cell=:sun,),status=NamedTuple()))
            PSE.move_object!(fixture.model,1,(cell=:shade,))
            fixture.environment.values[:shade]=7.0f0
        end
        for _ in 1:2
            PSE.step!(reference);PSE.step!(candidate)
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            @test PSE.refvalue(PSE.model_status(candidate.model,1),:signal)===escaped
        end
        @test escaped[]===26.0f0
        @test PSE.model_status(candidate.model,2).signal===18.0f0
        @test PSE.model_status(candidate.model,3).signal===6.0f0
        report=_reports(candidate,arm)
        return (;passed=true,arm,outputs,report,
            oracle=:ordinary_raw_history_mutable_spatial_sampling_cadence_and_moved_handles)
    end
end

"""Dispatch exactly one explicitly requested cheap feature case."""
function preparation_feature_case(case::Symbol=:initializer;kwargs...)
    case===:initializer && return preparation_initializer_feature_check(;kwargs...)
    case===:mixed_cadence && return preparation_mixed_cadence_feature_check(;kwargs...)
    case===:distributed && return preparation_distributed_feature_check(;kwargs...)
    case===:spatial && return preparation_spatial_feature_check(;kwargs...)
    throw(ArgumentError("Unknown focused preparation feature case: $case"))
end

end
