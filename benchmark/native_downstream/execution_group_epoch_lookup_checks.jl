module ExecutionGroupEpochLookupChecks

using Dates, Test, PlantSimEngine
const PSE = PlantSimEngine
export epoch_lookup_unit_checks, epoch_lookup_parity_checks, epoch_lookup_recompile_checks
_E()=getfield(Main,:ExecutionGroupEpochLookup)
_L()=getfield(Main,:ExecutionGroupLookupChecks)
_C()=getfield(Main,:GrowthInputReuseChecks)
_B()=getfield(Main,:NewbornBindingProgramChecks)
_F()=getfield(Main,:DirectPlannerFixtures)
_enable!(model)=Base.invokelatest(_E().enable_execution_group_epoch_lookup!,model)
_report(value)=Base.invokelatest(_E().execution_group_epoch_lookup_report,value)

function _evidence(simulation;positive=false)
    report=_report(simulation)
    @test report.enabled && report.v1.enabled
    c,b=report.counters,report.v1.counters
    @test c.epoch_attempts==c.epochs_validated+c.epochs_rejected
    @test b.lookups==b.slot_hits+b.slot_misses+c.trusted_empty_returns
    @test b.dictionary_lookups==b.slot_misses
    @test b.slot_misses==b.absent_slot_misses+b.out_of_range_misses+b.identity_misses
    @test c.nonempty_epoch_hits<=b.slot_hits
    @test b.dictionaries_built<=b.refresh_lookups_created
    if positive
        @test c.epochs_validated>0
        @test c.nonempty_epoch_hits>0
        @test b.slot_hits>0
    end
    return report
end
function _copy_plan(previous;groups=previous.groups,index=previous.groups_by_application_slot)
    return PSE.CompiledExecutionPlan(groups,previous.batches,index,previous.schedule,
        previous.model_revision,previous.environment_revision,previous.shared_target_plans)
end

"""Trusted empty slots, canonical queries, coverage corruption and epoch changes."""
function epoch_lookup_unit_checks()
    L=_L();model=L._empty_fixture()
    simulation=PSE.run!(model;steps=0,outputs=:all)
    previous,compiled=simulation.execution_plan,simulation.compiled
    ordinary=Dict(group.application.id=>group for group in previous.groups)
    _enable!(model)
    @testset "Epoch lookup proves absence without hiding old ID entries" begin
        lookup=PSE._previous_execution_groups_for_refresh(previous,compiled)
        @test lookup isa _E().EpochGroupLookup
        existing=compiled.applications_by_id[:existing]
        absent=compiled.applications_by_id[:first_membership]
        expected=ordinary[existing.id]
        @test PSE._previous_execution_group(lookup,existing)===expected
        @test PSE._previous_execution_group(lookup,absent)===nothing
        report=_evidence(simulation;positive=true)
        @test report.counters.trusted_empty_returns==1
        @test report.v1.counters.dictionaries_built==0
        @test report.dictionary_builds_avoided==1
        # A forged current shell in an empty slot can still name an old ID.
        # Its identity is not canonical: original ID fallback must find it.
        fake=L._fake_application(absent;id=:existing)
        @test PSE._previous_execution_group(lookup,fake)===expected
        @test PSE._previous_execution_group(lookup,PSE.CompiledModelApplication(existing.plan,existing.target_ids))===expected
        @test PSE._previous_execution_group(lookup,L._fake_application(existing;slot=0))===expected
        @test _report(simulation).v1.counters.dictionaries_built==1

        # Even a canonical vector replacement after validation cannot inherit
        # the earlier empty-slot proof: snapshot identity must still match.
        fresh=PSE._previous_execution_groups_for_refresh(previous,compiled)
        replacement=PSE.CompiledModelApplication(absent.plan,absent.target_ids)
        saved=compiled.applications[absent.slot]
        try
            compiled.applications[absent.slot]=replacement
            before=_report(simulation)
            @test PSE._previous_execution_group(fresh,replacement)===nothing
            after=_report(simulation)
            @test after.counters.trusted_empty_returns==before.counters.trusted_empty_returns
            @test after.v1.counters.dictionaries_built==before.v1.counters.dictionaries_built+1
        finally
            compiled.applications[absent.slot]=saved
        end

        index=copy(previous.groups_by_application_slot)
        index[existing.slot]=nothing
        missing=_copy_plan(previous;index)
        duplicate=_copy_plan(previous;groups=vcat(previous.groups,previous.groups))
        index=copy(previous.groups_by_application_slot)
        index[existing.slot]=PSE.CompiledApplicationExecutionGroup(expected.application,copy(expected.batches))
        unrelated=_copy_plan(previous;index)
        for invalid in (missing,duplicate,unrelated)
            before=_report(simulation)
            uncertain=PSE._previous_execution_groups_for_refresh(invalid,compiled)
            @test PSE._previous_execution_group(uncertain,existing)===expected
            @test PSE._previous_execution_group(uncertain,absent)===nothing
            after=_report(simulation)
            @test after.counters.epochs_rejected>before.counters.epochs_rejected
            @test after.counters.trusted_empty_returns==before.counters.trusted_empty_returns
            @test after.v1.counters.dictionaries_built==before.v1.counters.dictionaries_built+1
        end
        saved=compiled.applications
        try
            compiled.applications=reverse(saved)
            before=_report(simulation)
            reordered=PSE._previous_execution_groups_for_refresh(previous,compiled)
            @test PSE._previous_execution_group(reordered,existing)===expected
            @test _report(simulation).counters.epochs_rejected>before.counters.epochs_rejected
        finally
            compiled.applications=saved
        end
        return (;passed=true,report=_evidence(simulation;positive=true))
    end
end

function _mutate!(model,step,case)
    C=_C()
    if case===:generic
        if step==2
            PSE.register_object!(model,C._unit(2))
            PSE.register_object!(model,PSE.Object(:new;kind=:growth_input_gatherer))
            PSE.register_object!(model,C._unit(3;parent=:new))
            PSE.register_object!(model,PSE.Object(4;kind=:growth_input_unit,parent=:left,status=(signal=0.0,visits=0)))
        elseif step==3
            PSE.remove_object!(model,2);PSE.reparent_object!(model,3,:right)
        elseif step==4
            PSE.register_object!(model,C._unit(2;value=30.0f0));PSE.move_object!(model,1,(cell=:moved,))
        end
    elseif case===:first_membership && step==2
        PSE.register_object!(model,PSE.Object(2;kind=:later))
    end
    return nothing
end
"""One generic, existing feature or original downstream scientific pair."""
function epoch_lookup_parity_checks(case::Symbol=:xp;steps=nothing)
    C,L,F=_C(),_L(),_F();kind=case in (:xp,:pb) ? case : :generic
    count=steps===nothing ? (case in (:generic,:mixed_cadence) ? 4 : case in (:initializer,:distributed) ? 3 : 2) : steps
    initial_ids=nothing
    if case in (:xp,:pb)
        H=getfield(Main,:DirectPlannerMeasurements)
        config=H.construct_config(case;steps=count,nobjects=2,outputs=:all)
        a,b=F.construct_fixture(case,config),F.construct_fixture(case,config)
        left,right=a.model,b.model;initial_ids=b.initial_ids
    else
        factory=if case===:generic
            ()->_B()._rng_fixture(1)
        elseif case===:first_membership
            L._empty_fixture
        elseif case in (:initializer,:mixed_cadence)
            N=getfield(Main,:NewbornPreparationChecks)
            cadence=case===:mixed_cadence ? Hour(2) : Hour(1)
            ()->N.preparation_fixture(;source_every=cadence).model
        elseif case===:distributed
            D=getfield(Main,:NewbornDistributedChecks)
            ()->D.distributed_fixture(:from_status)
        else
            throw(ArgumentError("Unknown epoch lookup case: $case"))
        end
        left,right=factory(),factory()
    end
    reference=PSE.run!(left;steps=0,outputs=:all)
    candidate=C._prepare(right;enable! = _enable!,outputs=:all)
    @testset "Epoch lookup preserves $case science and lifecycle" begin
        @test _report(candidate).v1.counters.lookups==0
        previous=C._initial_pair(reference,candidate;kind)
        for step in 1:count
            _mutate!(reference.model,step,case);_mutate!(candidate.model,step,case)
            PSE.step!(reference);PSE.step!(candidate)
            previous=L._state(reference,candidate,previous;kind)
        end
        if case in (:xp,:pb)
            CR=getfield(Main,:CompiledRegionsExperiment)
            @test CR.downstream_work_report(candidate,initial_ids)==CR.downstream_work_report(reference,initial_ids)
        end
        report=_evidence(candidate;positive=case in (:xp,:generic,:first_membership))
        if case in (:xp,:first_membership)
            @test report.counters.trusted_empty_returns>0
            @test report.dictionary_builds_avoided>0
        end
        return (;passed=true,case,steps=count,report,
            oracle=:ordinary_exact_state_history_rng_refs_batch_types_ids_and_schedule)
    end
end

"""Bounded layout edits preserve continuation or the same ordinary rejection."""
function epoch_lookup_recompile_checks()
    C,L=_C(),_L();bounded=getfield(Main,:BoundedPreparation)
    left,right=_B()._rng_fixture(1),_B()._rng_fixture(1)
    Base.invokelatest(bounded.enable_bounded_preparation!,left)
    Base.invokelatest(bounded.enable_bounded_preparation!,right)
    reference=PSE.run!(left;steps=0,outputs=:all)
    candidate=C._prepare(right;enable! = _enable!,outputs=:all)
    outcomes=Any[]
    @testset "Epoch proof rejects old logical application identities" begin
        previous=C._initial_pair(reference,candidate)
        for simulation in (reference,candidate)
            PSE.register_object!(simulation.model,C._unit(2))
            PSE.register_object!(simulation.model,PSE.Object(:new;kind=:growth_input_gatherer))
            PSE.register_object!(simulation.model,C._unit(3;parent=:new))
            PSE.step!(simulation)
        end
        previous=L._state(reference,candidate,previous)
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
                PSE._mark_bindings_dirty!(model)
            end
            a,b=_B()._step_error(reference),_B()._step_error(candidate)
            @test isequal(a,b)
            if a!==nothing || b!==nothing
                push!(outcomes,(;case,qualification=:identical_ordinary_rejection,error=a));break
            end
            previous=L._state(reference,candidate,previous)
            push!(outcomes,(;case,qualification=:ordinary_continuation_parity))
        end
        report=_evidence(candidate;positive=true)
        if all(row->row.qualification===:ordinary_continuation_parity,outcomes)
            @test report.counters.epochs_rejected>0
            @test report.v1.counters.dictionaries_built>0
        end
        return (;passed=true,outcomes,report,bounded_both_arms=true)
    end
end

end # module
