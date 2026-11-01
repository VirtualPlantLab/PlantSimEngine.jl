module PBPreparationScaling

using Test, PlantSimEngine
const PSE = PlantSimEngine
const H = Main.DirectPlannerMeasurements
const F = Main.DirectPlannerFixtures
const M = Main.NativeDownstreamMeasurements
const CR = Main.CompiledRegionsExperiment
const DM = Main.XPDispatchRefreshMeasurements
const PB = Main.NativePBDriver

export PB_ARMS, pb_preparation_checks, register_pb_preparation_case!,
    screen_pb_preparation, pb_preparation_coverage

const PB_ARMS = (:ordinary_a,:ordinary_b,:bounded_graph,:typed_graph)
const OPTIONAL_ARMS = (:typed_barrier,)
const PROTOCOL = :pb_original_executor_preparation_scaling_v1

function _arms(arms)
    names=Tuple(Symbol(arm) for arm in arms)
    !isempty(names) && length(unique(names))==length(names) || error("Choose distinct PB arms")
    all(arm -> arm in (PB_ARMS...,OPTIONAL_ARMS...),names) || error("Unknown PB preparation arm")
    return names
end

function _dimensions(nobjects,steps)
    1<=nobjects<=256 && 1<=steps<=8 || error("PB scaling budget: 1-256 objects and 1-8 steps")
    return nothing
end

Base.@nospecializeinfer @noinline function _prepare(fixture,arm,outputs)
    @nospecialize fixture outputs
    return Base.invokelatest(DM.prepare_dispatch_refresh,fixture.model,arm;outputs)
end

Base.@nospecializeinfer @noinline function _advance!(simulation,steps)
    @nospecialize simulation
    Base.invokelatest(PSE.continue!,simulation;steps)
    return nothing
end

Base.@nospecializeinfer @noinline function _fingerprint(simulation)
    @nospecialize simulation
    return (state=Base.invokelatest(F.snapshot,simulation,:pb),
        scientific_rngs=Base.invokelatest(F.scientific_rngs,simulation.model))
end

Base.@nospecializeinfer @noinline function pb_preparation_coverage(simulation,arm)
    @nospecialize simulation
    report=Base.invokelatest(DM.dispatch_refresh_coverage,simulation,arm,:pb;
        require_growth=false)
    policy=DM.dispatch_refresh_policies(arm)
    counts=report.typed_output_preparation.counters
    if policy.typed_output_preparation
        counts.initial_applications_completed>0 && counts.initial_objects_prepared>0 ||
            error("PB typed preparation completed no initial object work")
        iszero(counts.growth_applications_completed) && iszero(counts.growth_objects_prepared) ||
            error("Original PB scaling fixture unexpectedly prepared growth-phase objects")
    end
    policy.trusted_index && error("PB preparation scaling must retain independent ordinary lookup behavior")
    return merge(report,(PB_preparation_protocol=PROTOCOL,
        interpretation=:initial_preparation_metadata_work_not_optimized_scientific_kernel_entries,
        expected_growth=false,numerical_models=:original_PlantBiophysics,
        steady_execution=:ordinary_PSE_executor_with_original_hard_calls))
end

function _same_shapes(left,right)
    keys(left.statuses)==keys(right.statuses) && keys(left.references)==keys(right.references) || return false
    all(key -> typeof(left.statuses[key])===typeof(right.statuses[key]),keys(left.statuses)) || return false
    return all(key -> typeof(left.references[key])===typeof(right.references[key]),keys(left.references))
end

Base.@nospecializeinfer @noinline function _check_pair(reference,candidate,previous)
    @nospecialize reference candidate previous
    @test isequal(Base.invokelatest(_fingerprint,reference),Base.invokelatest(_fingerprint,candidate))
    current=(Base.invokelatest(F.identities,reference.model),Base.invokelatest(F.identities,candidate.model))
    @test _same_shapes(current[1],current[2])
    @test F.same_identity_transitions(previous[1],previous[2],current[1],current[2])
    return current
end

"""Untimed original-PB state/history/RNG/type/reference preservation gate.

Start with objects=2/4, steps=2 and outputs=:all. Each arm receives a new
independent reference and candidate. Full snapshots and live canonical identity
transitions are checked after every step, outside any timing. This fixture has
no organ creation, so metadata benefits are preparation benefits; no newborn
or optimized numerical-kernel work is credited.
"""
Base.@nospecializeinfer @noinline function pb_preparation_checks(;
    nobjects::Int=2,steps::Int=2,outputs=:all,
    arms=(:ordinary_b,:bounded_graph,:typed_graph))
    _dimensions(nobjects,steps)
    names=_arms(arms)
    config=H.construct_config(:pb;steps,nobjects,outputs)
    evidence=Any[]
    @testset "PB preparation candidates retain original physics and references" begin
        for arm in names
            left=Base.invokelatest(F.construct_fixture,:pb,config)
            right=Base.invokelatest(F.construct_fixture,:pb,config)
            reference=Base.invokelatest(_prepare,left,:ordinary_a,outputs)
            candidate=Base.invokelatest(_prepare,right,arm,outputs)
            old_left=Base.invokelatest(F.identities,left.model)
            old_right=Base.invokelatest(F.identities,right.model)
            @test _same_shapes(old_left,old_right)
            @test all(key -> old_left.references[key]!==old_right.references[key],keys(old_left.references))
            previous=Base.invokelatest(_check_pair,reference,candidate,(old_left,old_right))
            initial_report=Base.invokelatest(pb_preparation_coverage,candidate,arm)
            for _ in 1:steps
                Base.invokelatest(PSE.step!,reference)
                Base.invokelatest(PSE.step!,candidate)
                previous=Base.invokelatest(_check_pair,reference,candidate,previous)
            end
            final_report=Base.invokelatest(pb_preparation_coverage,candidate,arm)
            @test final_report.typed_output_preparation.counters==initial_report.typed_output_preparation.counters
            @test final_report.graph_projection.counters==initial_report.graph_projection.counters
            work=Base.invokelatest(CR.downstream_work_report,candidate,right.initial_ids)
            @test work==Base.invokelatest(CR.downstream_work_report,reference,left.initial_ids)
            @test isempty(work.added_ids)
            @test work.objects==length(right.initial_ids)
            @test work.steps==steps
            push!(evidence,(arm,work,coverage=final_report,
                exact_state_history_rng_types_and_reference_transitions=true))
        end
    end
    return (passed=true,kind=:pb,config,evidence,benchmark_claim=false,
        scientific_models=:original_unmodified_PlantBiophysics,
        executor=:ordinary_reference_storage_and_original_call_execution,
        preservation_scope=:every_step_full_snapshot_numeric_types_rng_and_canonical_reference_identity)
end

"""Register one modest PB scaling screen, without executing science.

All enablement and normal preparation costs are charged. Construction uses the
unchanged original PB fixture for every independent sample. No typed numerical
driver, native columns, binding program, trusted lookup or future catalogue is
enabled. The lower phase is empty; untimed preservation gates check reference
identity instead of adding instrumentation copies to product timing.
"""
Base.@nospecializeinfer @noinline function register_pb_preparation_case!(
    name::Symbol=:pb_preparation_scaling;nobjects::Int=16,steps::Int=4,
    outputs=:none,arms=PB_ARMS,replace::Bool=false)
    _dimensions(nobjects,steps)
    names=_arms(arms)
    all(arm -> arm in names,PB_ARMS) || error("Include ordinary A/A, bounded_graph and typed_graph once")
    config=merge(H.construct_config(:pb;steps,nobjects,outputs),
        (measurement_protocol=PROTOCOL,
        policies_by_arm=Dict(arm=>DM.dispatch_refresh_policies(arm) for arm in names),
        statistical_unit=:one_fresh_PB_simulation,
        placebo_pair=(:ordinary_a,:ordinary_b),expected_growth=false,
        complete_cost_scope=:construction_enablement_normal_preparation_and_execution,
        preparation_scope=:warm_methods_fresh_model_and_status_state,
        execution_scope=:ordinary_executor_original_PB_hard_calls,
        reference_identity_checks=:separate_untimed_per_step_preservation_gate,
        interpretation=:PB_preparation_scaling_not_a_growth_or_new_numerical_kernel_benchmark))
    return M.register_case!(name;config,replace,packages=(PSE,PB.PB),
        variants=Tuple(M.VariantSpec(arm) for arm in names),
        construct=(config,variant)->Base.invokelatest(F.construct_fixture,:pb,config),
        prepare=(fixture,config,variant)->Base.invokelatest(_prepare,fixture,variant.name,config.outputs),
        lower=(simulation,fixture,config,variant)->nothing,
        execute! = (simulation,program,fixture,config,variant)->Base.invokelatest(_advance!,simulation,config.steps),
        fingerprint=(simulation,fixture,config)->Base.invokelatest(_fingerprint,simulation),
        coverage=(simulation,program,fixture,config,variant)->Base.invokelatest(pb_preparation_coverage,simulation,variant.name),
        work=(simulation,fixture,config)->Base.invokelatest(CR.downstream_work_report,simulation,fixture.initial_ids))
end

"""Four balanced cycles by default; preparation/execution/complete stay separate."""
function screen_pb_preparation(spec;repetitions::Int=4,measure_retained=false)
    1<=repetitions<=8 || error("Start with at most eight balanced screen cycles")
    return Base.invokelatest(M.screen_case,spec;baseline=:ordinary_a,repetitions,measure_retained)
end

end # module
