module FutureLayoutChecks

using Test, PlantSimEngine
const PSE=PlantSimEngine
const Fixtures=Main.FutureLayoutFixtures
const Measurements=Main.FutureLayoutMeasurements

export generic_future_layout_checks, downstream_future_layout_checks

Base.@nospecializeinfer @noinline function _check_generic_state(state,steps)
    @nospecialize state
    simulation,fixture=state[:simulation],state[:fixture]
    probe=Base.invokelatest(Fixtures.fixture_guard,fixture)
    expected=steps*(steps+1)÷2
    @test PSE.current_step(simulation)==steps
    @test probe.kernel_calls.creator==steps
    @test probe.kernel_calls.worker==expected
    @test probe.kernel_calls.child==expected
    @test probe.samples>0
    @test state[:guard].before.kernel_calls==(creator=0,worker=0,child=0)
    @test state[:guard].before.samples==state[:guard].after.samples==0
    @test state[:guard].unchanged
    @test state[:guard].task_rng_unchanged
    @test state[:guard].identity_guard.unchanged
    @test state[:guard].identity_guard.statuses>0
    @test state[:guard].identity_guard.references>0
    @test length(PSE.model_objects(simulation.model;kind=:future_unit))==steps
    for application in (:worker,:child)
        @test length(simulation.compiled.applications_by_id[application].target_ids)==steps
    end
    for id in 1:steps
        status=PSE.model_status(simulation.model,id)
        @test status.value isa Float32
        @test status.child_value isa Float32
        @test status.worker_visits==steps-id+1
        @test status.child_visits==steps-id+1
        for application in (:worker,:child)
            view=simulation.compiled.status_views_by_target[(application,PSE.ObjectId(id))]
            @test PSE.refvalue(view.status,:value)===PSE.refvalue(status,:value)
            @test PSE.refvalue(view.status,:child_value)===PSE.refvalue(status,:child_value)
        end
    end
    observations=Base.invokelatest(Fixtures.generic_observations,fixture)
    @test length(observations)==steps+2expected
    for observation in observations
        canonical=PSE.model_status(simulation.model,observation.object_id)
        for (name,reference) in observation.references
            @test reference===PSE.refvalue(canonical,name)
        end
    end
    return probe
end

"""
One correctness companion, not a cold timing. Original ordinary control runs
first, so subsequent precompile acceptance is not a claim of cold code-cache
work. Explicit targetless worker+child must match actual observed postbirth
kernel signatures and accepted requests; status coverage is separately checked.
Call once per arm, beginning with :future_precompile. All execution is through
the staged Any/invokelatest harness, never a four-Simulation generator.
"""
Base.@nospecializeinfer @noinline function generic_future_layout_checks(;
    arm::Symbol=:future_precompile,steps::Int=2,max_requests::Int=12,
    status_max_requests::Int=2,progress_path=nothing)
    reports=Dict{Symbol,Any}()
    @testset "Type-only future Float32 targetless worker and hard-call child" begin
        control=Base.invokelatest(Measurements.future_layout_case_state,:generic,
            :reference_executor;steps,outputs=:all,record_types=true,progress_path)
        candidate=Base.invokelatest(Measurements.future_layout_case_state,:generic,
            arm;steps,outputs=:all,record_types=true,max_requests,status_max_requests,progress_path)
        left=Base.invokelatest(_check_generic_state,control,steps)
        right=Base.invokelatest(_check_generic_state,candidate,steps)
        @test isequal(Base.invokelatest(Fixtures.portable_snapshot,candidate[:simulation]),
            Base.invokelatest(Fixtures.portable_snapshot,control[:simulation]))
        @test left.model_rngs==right.model_rngs
        @test left.kernel_calls==right.kernel_calls
        @test left.samples==right.samples
        catalogue=candidate[:catalogue]
        if arm in (:future_precompile,:combined)
            Future=getfield(Main,:FutureLayouts)
            report=Base.invokelatest(Future.future_layout_report,catalogue)
            @test Set((:worker,:child)) ⊆ Set(report.targetless_before)
            @test any(row->Set((:worker,:child)) ⊆
                Set(row.represented_targetless_applications),report.scenarios)
            @test report.status_requests_attempted>0
            @test report.status_requests_accepted>0
            @test report.scientific_kernels_executed===false
            @test report.sampled_for_signature_discovery===false
            @test report.task_rng_restored
            status_matches=Base.invokelatest(Future.match_future_status_layouts,catalogue,
                candidate[:simulation];object_ids=1:steps)
            @test status_matches.observed>0
            @test status_matches.matched==status_matches.observed
            observations=Base.invokelatest(Fixtures.generic_observations,candidate[:fixture])
            matches=Base.invokelatest(Future.match_observed_kernel_layouts,catalogue,observations)
            @test !isempty(matches.catalogue_reports)
            for application in (:worker,:child)
                matching=[entry.by_application[application] for entry in matches.catalogue_reports
                    if haskey(entry.by_application,application)]
                @test !isempty(matching)
                @test any(row->row.observations>0 &&
                    row.requested_matches==row.observations,matching)
                @test any(row->row.observations>0 &&
                    row.accepted_matches==row.observations,matching)
            end
            reports[:future]=report
            reports[:status_matches]=status_matches
            reports[:actual_kernel_matches]=matches
        else
            @test catalogue===nothing
        end
        if arm in (:bounded_preparation,:combined)
            bounded=Base.invokelatest(getfield(Main,:BoundedPreparation).bounded_preparation_report,
                candidate[:simulation])
            @test bounded.scene_entries>0
            @test bounded.metadata_symbol_tables>0
            reports[:bounded]=bounded
        end
        reports[:actual_work]=right.kernel_calls
    end
    return (;passed=true,arm,steps,reports,
        interpretation=:correctness_companion_with_actual_entry_types_not_cold_timing_or_cache_hit_proof)
end

Base.@nospecializeinfer @noinline function _downstream_state_checks(state,kind,steps)
    @nospecialize state
    simulation,fixture=state[:simulation],state[:fixture]
    @test PSE.current_step(simulation)==steps
    @test state[:guard].unchanged
    @test state[:guard].task_rng_unchanged
    @test state[:guard].identity_guard.unchanged
    @test state[:guard].identity_guard.statuses>0
    @test state[:guard].identity_guard.references>0
    @test state[:guard].before==state[:guard].after
    initial=Set(fixture.initial_ids)
    newborns=[object.id for object in PSE.model_objects(simulation.model)
        if !(object.id in initial)]
    if kind===:pb
        @test length(newborns)==steps
        @test fixture.probe.creator_calls==steps
        @test state[:guard].before.kernel_calls.creator==0
        for application in (:energy,:photosynthesis,:stomata)
            @test length(simulation.compiled.applications_by_id[application].target_ids)==steps
            for id in newborns
                canonical=PSE.model_status(simulation.model,id)
                @test canonical.Ra_SW_f isa Float64
                view=simulation.compiled.status_views_by_target[(application,id)]
                for name in (:Ra_SW_f,:aPPFD,:d)
                    @test PSE.refvalue(view.status,name)===PSE.refvalue(canonical,name)
                end
            end
        end
    elseif kind===:xp
        @test length(newborns)>=3
        @test !isempty(state[:guard].before.model_rngs)
        @test state[:guard].before.kernel_calls===nothing
        for object in PSE.model_objects(simulation.model)
            object.id in newborns || continue
            @test PSE.source_node(simulation.model,object.id)!==nothing
            @test PSE.object_id(simulation.model,object.status)==object.id
        end
    end
    return (;newborns,guard=Base.invokelatest(Fixtures.fixture_guard,fixture))
end

"""One downstream correctness companion; no original scientific method is wrapped.

Exact state, numeric types, retained history, topology and copied scientific RNG
draws are compared with the ordinary executor. Finite postbirth status matches
are reported separately from accepted requests. XP's targeted transient call
schemas may miss this next-archetype catalog and are not credited as compiled.
Run PB first (two births); only then the four-day original XP growth case.
"""
Base.@nospecializeinfer @noinline function downstream_future_layout_checks(kind::Symbol=:pb;
    arm::Symbol=:future_precompile,steps::Int=kind===:xp ? 4 : 2,
    max_requests::Int=12,status_max_requests::Int=2,progress_path=nothing)
    kind in (:pb,:xp) || throw(ArgumentError("Expected :pb or :xp"))
    reports=Dict{Symbol,Any}()
    @testset "Original downstream kernels with type-only future metadata" begin
        control=Base.invokelatest(Measurements.future_layout_case_state,kind,
            :reference_executor;steps,outputs=:all,record_types=true,progress_path)
        candidate=Base.invokelatest(Measurements.future_layout_case_state,kind,
            arm;steps,outputs=:all,record_types=true,max_requests,status_max_requests,progress_path)
        left=Base.invokelatest(_downstream_state_checks,control,kind,steps)
        right=Base.invokelatest(_downstream_state_checks,candidate,kind,steps)
        @test isequal(Base.invokelatest(Fixtures.portable_snapshot,candidate[:simulation];kind),
            Base.invokelatest(Fixtures.portable_snapshot,control[:simulation];kind))
        @test left.guard==right.guard
        @test Set(left.newborns)==Set(right.newborns)
        catalogue=candidate[:catalogue]
        if arm in (:future_precompile,:combined)
            Future=getfield(Main,:FutureLayouts)
            report=Base.invokelatest(Future.future_layout_report,catalogue)
            @test report.total_requests_attempted>0
            @test report.total_requests_accepted>0
            @test report.scientific_kernels_executed===false
            @test report.sampled_for_signature_discovery===false
            @test report.task_rng_restored
            if kind===:pb
                @test Set((:energy,:photosynthesis,:stomata)) ⊆ Set(report.targetless_before)
                @test any(row->Set((:energy,:photosynthesis,:stomata)) ⊆
                    Set(row.represented_targetless_applications),report.scenarios)
            end
            status_matches=Base.invokelatest(Future.match_future_status_layouts,catalogue,
                candidate[:simulation];object_ids=right.newborns)
            @test status_matches.observed>0
            @test status_matches.matched>0
            # Full coverage is asserted only for the simple complete PB shapes.
            kind===:pb && @test status_matches.matched==status_matches.observed
            reports[:future]=report
            reports[:newborn_status_matches]=status_matches
        else
            @test catalogue===nothing
        end
        if arm in (:bounded_preparation,:combined)
            bounded=Base.invokelatest(getfield(Main,:BoundedPreparation).bounded_preparation_report,
                candidate[:simulation])
            @test bounded.scene_entries>0
            @test bounded.metadata_symbol_tables>0
            reports[:bounded]=bounded
        end
        reports[:actual_work]=(steps,newborns=length(right.newborns),probe=right.guard)
    end
    return (;passed=true,kind,arm,steps,reports,
        scientific_kernels=:original_unmodified_methods,
        interpretation=:finite_postbirth_type_coverage_not_actual_compiler_cache_hit)
end

end
