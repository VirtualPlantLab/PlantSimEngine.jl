module ExecutionGroupLookupChecks

using Dates, Test, PlantSimEngine
const PSE = PlantSimEngine
export execution_group_lookup_unit_checks, execution_group_lookup_growth_checks,
    execution_group_lookup_recompile_checks, execution_group_lookup_feature_checks,
    execution_group_lookup_downstream_checks
_L() = getfield(Main, :ExecutionGroupLookup)
_C() = getfield(Main, :GrowthInputReuseChecks)
_B() = getfield(Main, :NewbornBindingProgramChecks)
_F() = getfield(Main, :DirectPlannerFixtures)
_enable!(model) = Base.invokelatest(_L().enable_execution_group_lookup!, model)
_report(value) = Base.invokelatest(_L().execution_group_lookup_report, value)

function _empty_fixture()
    return PSE.CompositeModel(PSE.Object(1;kind=:existing);
        applications=(
            PSE.ModelSpec(_C().Source();name=:existing,on=PSE.Many(kind=:existing),every=Hour(1)),
            PSE.ModelSpec(_C().Source();name=:first_membership,on=PSE.Many(kind=:later),every=Hour(1)),
        ),environment=(duration=Hour(1),))
end
function _fake_application(application;slot=application.slot,id=application.id)
    plan=application.plan
    values=map(fieldnames(typeof(plan))) do name
        name===:slot ? slot : name===:id ? id : getfield(plan,name)
    end
    return PSE.CompiledModelApplication(PSE.CompiledApplicationPlan(values...),application.target_ids)
end
function _plan_shape(simulation)
    groups=[(id=group.application.id,
        batches=[(type=typeof(batch),ids=[PSE._model_execution_target_id(batch.targets,index)
            for index in eachindex(batch.targets)],target_types=typeof.(collect(batch.targets)))
            for batch in group.batches]) for group in simulation.execution_plan.groups]
    schedule=simulation.execution_plan.schedule
    return (;groups,next_due=copy(schedule.next_due_steps),heap=copy(schedule.heap),last_step=schedule.last_step)
end
function _state(reference,candidate,previous;kind=:generic)
    next=_C()._pair_state(reference,candidate,previous;kind)
    @test isequal(_plan_shape(candidate),_plan_shape(reference))
    _C()._live_bindings(reference);_C()._live_bindings(candidate)
    return next
end
function _evidence(simulation;positive=false)
    report=_report(simulation)
    @test report.enabled
    counts=report.counters
    @test counts.slot_hits+counts.slot_misses==counts.lookups
    @test counts.slot_misses==counts.absent_slot_misses+counts.out_of_range_misses+counts.identity_misses
    @test counts.dictionary_lookups==counts.slot_misses
    @test counts.dictionaries_built<=counts.refresh_lookups_created
    if positive
        @test counts.refresh_lookups_created>0
        @test counts.slot_hits>0
    end
    return report
end

"""Exact group identity on hits; original ID lookup on every guarded miss."""
function execution_group_lookup_unit_checks()
    model=_empty_fixture()
    simulation=PSE.run!(model;steps=0,outputs=:all)
    compiled=simulation.compiled
    previous=simulation.execution_plan
    ordinary=PSE._previous_execution_groups_for_refresh(previous,compiled)
    @testset "Guarded previous-group selection" begin
        @test ordinary isa Dict
        @test !_report(model).enabled
        cache=model.binding_cache
        _enable!(model)
        @test model.binding_cache===cache
        lookup=PSE._previous_execution_groups_for_refresh(previous,compiled)
        existing=compiled.applications_by_id[:existing]
        absent=compiled.applications_by_id[:first_membership]
        expected=ordinary[existing.id]
        @test PSE._previous_execution_group(lookup,existing)===expected
        @test _report(model).counters.dictionaries_built==0
        @test PSE._previous_execution_group(lookup,absent)===nothing
        @test _report(model).counters.dictionaries_built==1
        # Another shell with the same immutable plan must use the old ID map.
        replacement=PSE.CompiledModelApplication(existing.plan,existing.target_ids)
        @test PSE._previous_execution_group(lookup,replacement)===get(ordinary,replacement.id,nothing)
        @test PSE._previous_execution_group(lookup,_fake_application(existing;slot=0))===expected
        @test PSE._previous_execution_group(lookup,_fake_application(existing;slot=length(previous.groups_by_application_slot)+7))===expected
        @test PSE._previous_execution_group(lookup,_fake_application(existing;id=:missing))===nothing
        @test _report(model).counters.dictionaries_built==1
        report=_evidence(simulation;positive=true)
        @test report.counters.absent_slot_misses>0
        @test report.counters.identity_misses>0
        @test report.counters.out_of_range_misses==2
        return (;passed=true,report)
    end
end

"""Growth, mixed target types, reparent/remove, re-addition and movement."""
function execution_group_lookup_growth_checks()
    C=_C()
    reference=PSE.run!(_B()._rng_fixture(1);steps=0,outputs=:all)
    candidate=C._prepare(_B()._rng_fixture(1);enable! = _enable!,outputs=:all)
    @testset "Slot lookup preserves ordinary execution-plan refresh" begin
        @test _report(candidate).counters.refresh_lookups_created==0
        previous=C._initial_pair(reference,candidate)
        cells=map(sim->PSE.refvalue(PSE.model_status(sim.model,1),:signal),(reference,candidate))
        for step in 1:4
            for simulation in (reference,candidate)
                model=simulation.model
                if step==2
                    PSE.register_object!(model,C._unit(2))
                    PSE.register_object!(model,PSE.Object(:new;kind=:growth_input_gatherer))
                    PSE.register_object!(model,C._unit(3;parent=:new))
                    # A new concrete Status type cannot append to the old
                    # homogeneous target vector; retain the ordinary fallback.
                    PSE.register_object!(model,PSE.Object(4;kind=:growth_input_unit,parent=:left,
                        status=(signal=0.0,visits=0)))
                elseif step==3
                    PSE.reparent_object!(model,3,:right)
                    PSE.remove_object!(model,2)
                elseif step==4
                    PSE.register_object!(model,C._unit(2;value=30.0f0))
                    PSE.move_object!(model,1,(cell=:moved,))
                end
                PSE.step!(simulation)
            end
            previous=_state(reference,candidate,previous)
            @test PSE.refvalue(PSE.model_status(reference.model,1),:signal)===cells[1]
            @test PSE.refvalue(PSE.model_status(candidate.model,1),:signal)===cells[2]
        end
        report=_evidence(candidate;positive=true)
        return (;passed=true,report,
            oracle=:ordinary_state_history_rng_live_refs_and_execution_plan_structure)
    end
end

"""Use bounded metadata in BOTH arms for changing authored layouts/models.

An unbounded Simulation fixes its wide metadata tuple types at preparation.
These edits are therefore qualified separately, using the existing bounded
policy. If the ordinary executor rejects an edit, require the same rejection
and stop rather than claim continuation that the control does not support.
"""
function execution_group_lookup_recompile_checks()
    C=_C();bounded=getfield(Main,:BoundedPreparation)
    left,right=_B()._rng_fixture(1),_B()._rng_fixture(1)
    Base.invokelatest(bounded.enable_bounded_preparation!,left)
    Base.invokelatest(bounded.enable_bounded_preparation!,right)
    reference=PSE.run!(left;steps=0,outputs=:all)
    candidate=C._prepare(right;enable! = _enable!,outputs=:all)
    outcomes=Any[]
    @testset "Bounded ordinary and lookup retain edited execution semantics" begin
        previous=C._initial_pair(reference,candidate)
        cells=map(sim->PSE.refvalue(PSE.model_status(sim.model,1),:signal),(reference,candidate))
        # Establish genuine runtime hits before the semantic edit gates.
        for simulation in (reference,candidate)
            PSE.register_object!(simulation.model,C._unit(2))
            PSE.step!(simulation)
        end
        previous=_state(reference,candidate,previous)
        for case in (:reorder,:replacement)
            for simulation in (reference,candidate)
                model=simulation.model
                if case===:reorder
                    reverse!(model.applications)
                else
                    index=findfirst(spec->spec.name===:source,model.applications)
                    model.applications[index]=PSE.ModelSpec(_B().Writer(2.0f0);
                        name=:source,on=PSE.Many(kind=:growth_input_unit),every=Hour(1))
                end
                # This is the invalidation used after a graph-editor spec edit.
                PSE._mark_bindings_dirty!(model)
            end
            left_error,right_error=_B()._step_error(reference),_B()._step_error(candidate)
            @test isequal(left_error,right_error)
            if left_error!==nothing || right_error!==nothing
                push!(outcomes,(;case,qualification=:identical_ordinary_rejection,
                    reference_error=left_error,candidate_error=right_error))
                break
            end
            previous=_state(reference,candidate,previous)
            @test PSE.refvalue(PSE.model_status(reference.model,1),:signal)===cells[1]
            @test PSE.refvalue(PSE.model_status(candidate.model,1),:signal)===cells[2]
            push!(outcomes,(;case,qualification=:ordinary_continuation_parity))
        end
        report=_evidence(candidate;positive=true)
        if all(row->row.qualification===:ordinary_continuation_parity,outcomes)
            @test report.counters.identity_misses>0
        end
        return (;passed=true,report,outcomes,bounded_both_arms=true,
            oracle=:bounded_ordinary_edit_continuation_or_identical_rejection)
    end
end

"""One existing initializer/temporal fixture, or targetless first membership."""
function execution_group_lookup_feature_checks(case::Symbol=:initializer)
    C=_C()
    if case===:first_membership
        factory=_empty_fixture
        steps=2
    elseif case in (:initializer,:mixed_cadence,:distributed)
        if case===:distributed
            D=getfield(Main,:NewbornDistributedChecks)
            factory=()->D.distributed_fixture(:from_status)
        else
            N=getfield(Main,:NewbornPreparationChecks)
            cadence=case===:mixed_cadence ? Hour(2) : Hour(1)
            factory=()->N.preparation_fixture(;source_every=cadence).model
        end
        steps=case===:mixed_cadence ? 4 : 3
    else
        throw(ArgumentError("Choose :first_membership, :initializer, :mixed_cadence or :distributed"))
    end
    reference=PSE.run!(factory();steps=0,outputs=:all)
    candidate=C._prepare(factory();enable! = _enable!,outputs=:all)
    @testset "Lookup preserves $case execution groups and live caches" begin
        previous=C._initial_pair(reference,candidate)
        for step in 1:steps
            for simulation in (reference,candidate)
                if case===:first_membership && step==2
                    PSE.register_object!(simulation.model,PSE.Object(2;kind=:later))
                end
                PSE.step!(simulation)
            end
            previous=_state(reference,candidate,previous)
        end
        report=_evidence(candidate;positive=case===:first_membership)
        if case===:first_membership
            @test report.counters.absent_slot_misses>0
            @test PSE.model_status(candidate.model,2).visits==1
        end
        return (;passed=true,case,report)
    end
end

"""Independent original PB/XP, with no numerical driver or binding prototype."""
function execution_group_lookup_downstream_checks(kind::Symbol=:xp;steps=2)
    kind in (:xp,:pb) || throw(ArgumentError("Choose :xp or :pb"))
    C,F=_C(),_F();H=getfield(Main,:DirectPlannerMeasurements)
    config=H.construct_config(kind;steps,nobjects=2,outputs=:all)
    left,right=F.construct_fixture(kind,config),F.construct_fixture(kind,config)
    reference=PSE.run!(left.model;steps=0,outputs=:all)
    candidate=C._prepare(right.model;enable! = _enable!,outputs=:all)
    @testset "Original downstream execution under guarded group lookup" begin
        previous=C._initial_pair(reference,candidate;kind)
        for _ in 1:steps
            PSE.step!(reference);PSE.step!(candidate)
            previous=_state(reference,candidate,previous;kind)
        end
        CR=getfield(Main,:CompiledRegionsExperiment)
        @test CR.downstream_work_report(candidate,right.initial_ids)==CR.downstream_work_report(reference,left.initial_ids)
    end
    return (;passed=true,kind,steps,report=_evidence(candidate;positive=kind===:xp),
        qualification=kind===:xp ? :actual_growth_slot_lookup : :static_regression_no_lookup_credit)
end

end # module
