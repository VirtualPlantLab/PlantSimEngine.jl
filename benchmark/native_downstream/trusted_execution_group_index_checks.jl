module TrustedExecutionGroupIndexChecks

using Dates, Test, PlantSimEngine
const PSE=PlantSimEngine
export trusted_index_unit_checks, trusted_index_parity_checks, trusted_index_recompile_checks
_T()=getfield(Main,:TrustedExecutionGroupIndex)
_L()=getfield(Main,:ExecutionGroupLookupChecks)
_E()=getfield(Main,:ExecutionGroupEpochLookupChecks)
_C()=getfield(Main,:GrowthInputReuseChecks)
_B()=getfield(Main,:NewbornBindingProgramChecks)
_F()=getfield(Main,:DirectPlannerFixtures)
_enable!(model)=Base.invokelatest(_T().enable_trusted_execution_group_index!,model)
_report(value)=Base.invokelatest(_T().trusted_execution_group_index_report,value)
function _evidence(simulation;positive=false)
    report=_report(simulation);c=report.counters
    @test report.enabled
    @test c.refresh_attempts==c.certificate_hits+c.certificate_misses
    @test c.lookup_attempts==c.trusted_group_hits+c.trusted_empty_returns+c.fallback_queries
    @test c.fallback_lookups_created<=c.fallback_queries
    @test report.registry_entries.indices<=report.registry_capacities.indices
    @test report.registry_entries.logical_stamps<=report.registry_capacities.logical_stamps
    if positive
        @test c.indices_certified>0
        @test c.certificate_hits>0
        @test c.trusted_group_hits>0
    end
    return report
end

"""Only certified exact index/list/token and canonical application identities qualify."""
function trusted_index_unit_checks()
    T,L,E=_T(),_L(),_E()
    model=L._empty_fixture();_enable!(model)
    simulation=PSE.run!(model;steps=0,outputs=:all)
    previous,compiled=simulation.execution_plan,simulation.compiled
    expected=Dict(group.application.id=>group for group in previous.groups)
    existing=compiled.applications_by_id[:existing]
    absent=compiled.applications_by_id[:first_membership]
    @testset "Construction certificate controls trusted index lookup" begin
        @test _report(simulation).counters.logical_stamps_built==1
        @test _report(simulation).counters.refresh_attempts==0
        lookup=PSE._try_trusted_execution_group_lookup(previous,compiled)
        @test lookup isa T.TrustedLookup
        @test PSE._previous_execution_group(lookup,existing)===expected[:existing]
        @test PSE._previous_execution_group(lookup,absent)===nothing
        report=_evidence(simulation;positive=true)
        @test report.counters.trusted_empty_returns==1
        @test report.counters.fallback_queries==0
        @test report.fallback_epoch.counters.epoch_attempts==0

        # Same old ID and empty slot do not make a new shell canonical.
        fake=L._fake_application(absent;id=:existing)
        @test PSE._previous_execution_group(lookup,fake)===expected[:existing]
        @test PSE._previous_execution_group(lookup,L._fake_application(existing;slot=0))===expected[:existing]
        @test _report(simulation).counters.fallback_lookups_created==1

        # Count-only/manual indices and structurally equal copies are not
        # construction-certified, even if all their entries happen to agree.
        manual=PSE._execution_groups_by_application_slot(previous.groups,
            length(compiled.scenario_plan.applications))
        copies=(copy(previous.groups_by_application_slot),manual)
        for index in copies
            untrusted=E._copy_plan(previous;index)
            before=_report(simulation)
            fallback=PSE._try_trusted_execution_group_lookup(untrusted,compiled)
            @test PSE._previous_execution_group(fallback,existing)===expected[:existing]
            after=_report(simulation)
            @test after.counters.certificate_misses>before.counters.certificate_misses
            @test after.counters.trusted_group_hits==before.counters.trusted_group_hits
            @test after.counters.fallback_queries>before.counters.fallback_queries
        end
        ghost=copy(previous.groups_by_application_slot)
        real=expected[:existing]
        ghost[existing.slot]=PSE.CompiledApplicationExecutionGroup(real.application,copy(real.batches))
        corrupted=E._copy_plan(previous;index=ghost)
        fallback=PSE._try_trusted_execution_group_lookup(corrupted,compiled)
        @test PSE._previous_execution_group(fallback,existing)===real

        # The canonical builder observes duplicate slots before overwriting;
        # the baseline result remains usable only by the ordinary fallback.
        duplicates=vcat(previous.groups,previous.groups)
        bad_index=PSE._execution_groups_by_application_slot(duplicates,compiled)
        before=_report(simulation)
        bad=E._copy_plan(previous;groups=duplicates,index=bad_index)
        fallback=PSE._try_trusted_execution_group_lookup(bad,compiled)
        @test PSE._previous_execution_group(fallback,existing)===real
        @test _report(simulation).counters.duplicate_slots_rejected>0
        @test _report(simulation).counters.indices_rejected>0
        @test _report(simulation).counters.certificate_misses>before.counters.certificate_misses

        # An independently copied group-list identity cannot borrow a proof.
        copied=E._copy_plan(previous;groups=copy(previous.groups))
        before=_report(simulation)
        fallback=PSE._try_trusted_execution_group_lookup(copied,compiled)
        @test PSE._previous_execution_group(fallback,existing)===real
        @test _report(simulation).counters.certificate_misses>before.counters.certificate_misses

        # Bound the identity cache, and reject a deliberately mismatched weak
        # key rather than relying on an objectid number alone.
        cache=T.IdentityFIFO{T.LogicalStamp}(2)
        keys=[Ref(i) for i in 1:3]
        stamps=[T.LogicalStamp(WeakRef(key),WeakRef(model),WeakRef[]) for key in keys]
        for i in 1:3
            T._put!(cache,keys[i],stamps[i])
        end
        @test length(cache.entries)==2
        @test T._get(cache,keys[1])===nothing
        @test T._get(cache,keys[3])===stamps[3]
        cache.entries[objectid(keys[3])]=stamps[2]
        @test T._get(cache,keys[3])===nothing
        return (;passed=true,report=_evidence(simulation;positive=true))
    end
end

"""One original XP/PB or existing generic/lifecycle paired scientific case."""
function trusted_index_parity_checks(case::Symbol=:xp;steps=nothing)
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
            throw(ArgumentError("Unknown trusted-index case: $case"))
        end
        left,right=factory(),factory()
    end
    reference=PSE.run!(left;steps=0,outputs=:all)
    candidate=C._prepare(right;enable! = _enable!,outputs=:all)
    token=_T()._logical_epoch(candidate.compiled)
    before_stamps=_report(candidate).counters.logical_stamps_built
    @testset "Construction-trusted lookup preserves $case" begin
        @test _report(candidate).counters.refresh_attempts==0
        previous=C._initial_pair(reference,candidate;kind)
        for step in 1:count
            _E()._mutate!(reference.model,step,case)
            _E()._mutate!(candidate.model,step,case)
            PSE.step!(reference);PSE.step!(candidate)
            previous=L._state(reference,candidate,previous;kind)
            @test _T()._logical_epoch(candidate.compiled)===token
        end
        if case in (:xp,:pb)
            CR=getfield(Main,:CompiledRegionsExperiment)
            @test CR.downstream_work_report(candidate,initial_ids)==CR.downstream_work_report(reference,initial_ids)
        end
        report=_evidence(candidate;positive=case in (:xp,:generic,:first_membership))
        @test report.counters.logical_stamps_built==before_stamps
        if case in (:xp,:first_membership)
            @test report.counters.trusted_empty_returns>0
        end
        return (;passed=true,case,steps=count,report,
            oracle=:ordinary_exact_state_history_rng_refs_execution_targets_and_schedule)
    end
end

"""Fresh logical epochs reject the old certificate, then certify new indices."""
function trusted_index_recompile_checks()
    C,L=_C(),_L();bounded=getfield(Main,:BoundedPreparation)
    left,right=_B()._rng_fixture(1),_B()._rng_fixture(1)
    Base.invokelatest(bounded.enable_bounded_preparation!,left)
    Base.invokelatest(bounded.enable_bounded_preparation!,right)
    reference=PSE.run!(left;steps=0,outputs=:all)
    candidate=C._prepare(right;enable! = _enable!,outputs=:all)
    outcomes=Any[]
    @testset "Trusted certificate follows recompile and replacement epochs" begin
        previous=C._initial_pair(reference,candidate)
        for simulation in (reference,candidate)
            _E()._mutate!(simulation.model,2,:generic);PSE.step!(simulation)
        end
        previous=L._state(reference,candidate,previous)
        for case in (:reorder,:replacement)
            old_token=_T()._logical_epoch(candidate.compiled)
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
            @test _T()._logical_epoch(candidate.compiled)!==old_token
            push!(outcomes,(;case,qualification=:ordinary_continuation_parity))
        end
        report=_evidence(candidate;positive=true)
        if all(row->row.qualification===:ordinary_continuation_parity,outcomes)
            @test report.counters.certificate_misses>0
            @test report.counters.logical_stamps_built>=3
            @test report.counters.fallback_lookups_created>0
        end
        return (;passed=true,outcomes,report,bounded_both_arms=true)
    end
end

end # module
