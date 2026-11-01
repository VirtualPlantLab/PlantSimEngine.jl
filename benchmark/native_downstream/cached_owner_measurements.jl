module CachedOwnerMeasurements

using Test, PlantSimEngine
const PSE=PlantSimEngine
const F=Main.DirectPlannerFixtures
const H=Main.DirectPlannerMeasurements
const M=Main.NativeDownstreamMeasurements
const CR=Main.CompiledRegionsExperiment
const PT=Main.PersistentTightProgram
const Audit=Main.PersistentXPSourceAudit

export ARMS, policies, new_caches, lower_candidate!, candidate_report,
    candidate_regions, cached_owner_downstream_checks, register_cached_owner_case!,
    screen_cached_owner

# All four typed arms have the same logical preparation. This factorial screen
# estimates the two new mechanisms independently, rather than changing storage,
# source models, preparation policy, and runtime together.
const ARMS=(:ordinary_a,:ordinary_b,:preparation_only,:persistent,
    :proof_only,:owner_only,:combined)
function policies(arm)
    arm in ARMS || throw(ArgumentError("Unknown cached-proof/owner arm: $arm"))
    return (preparation=arm ∉ (:ordinary_a,:ordinary_b),
        typed=arm ∉ (:ordinary_a,:ordinary_b,:preparation_only),
        proof=arm in (:proof_only,:combined),owner=arm in (:owner_only,:combined))
end
_proof()=getfield(Main,:CachedDeclarationProofs)
_owners()=getfield(Main,:ColdOwnerProgram)
new_caches(;capacity=2048)=(
    proof_only=Base.invokelatest(_proof().DeclarationProofCache;capacity),
    combined=Base.invokelatest(_proof().DeclarationProofCache;capacity))
_cache(caches,arm)=policies(arm).proof ? getproperty(caches,arm) : nothing
_proof_report(cache)=cache===nothing ? nothing :
    Base.invokelatest(_proof().declaration_proof_report,cache)

Base.@nospecializeinfer @noinline function _prepare(fixture,config,arm)
    @nospecialize fixture config
    if policies(arm).preparation
        Main.BoundedPreparation.enable_bounded_preparation!(fixture.model)
        Main.GraphRowProjection.enable_graph_row_projection!(fixture.model)
        Main.TypedOutputPreparation.enable_typed_output_preparation!(fixture.model)
    end
    return PSE.run!(fixture.model;steps=0,outputs=config.outputs)
end

"""Explicit per-simulation policies; ordinary controls acquire no backend hooks.

The cache snapshot is charged to installation. Cache capacity/population are not
reset between independent scenes. Warm screens prime each arm in their untimed
warmup, and retain the initial population's counters in that warmup record.
"""
Base.@nospecializeinfer @noinline function lower_candidate!(simulation,arm;
    caches=nothing,proof_cache=nothing,count_calls=false)
    @nospecialize simulation
    policy=policies(arm)
    cache=policy.proof ? (proof_cache===nothing ? _cache(caches,arm) : proof_cache) : nothing
    before=_proof_report(cache)
    if policy.owner
        Base.invokelatest(_owners().lower_cold_owner!,simulation;proof_cache=cache,count_calls)
    elseif policy.typed
        if policy.proof
            Base.invokelatest(PT.lower_persistent_tight!,simulation;
                declaration_policy=cache,count_calls)
        else
            Base.invokelatest(PT.lower_persistent_tight!,simulation;count_calls)
        end
    end
    return (arm=arm,proof_cache=cache,cache_before=before)
end
function candidate_report(simulation,arm)
    policies(arm).typed || return nothing
    return policies(arm).owner ? Base.invokelatest(_owners().cold_owner_report,simulation) :
        Base.invokelatest(PT.persistent_tight_report,simulation)
end
function candidate_regions(simulation,arm)
    policies(arm).typed || return ()
    return policies(arm).owner ? Base.invokelatest(_owners().cold_owner_regions,simulation) :
        Base.invokelatest(PT.persistent_regions,simulation)
end
Base.@nospecializeinfer @noinline function _advance!(simulation,steps)
    @nospecialize simulation
    PSE.continue!(simulation;steps)
    return nothing
end
_fingerprint(simulation,kind)=(state=F.snapshot(simulation,kind),rng=F.scientific_rngs(simulation.model))
function _shape_parity(left,right)
    keys(left.statuses)==keys(right.statuses) && keys(left.references)==keys(right.references) || return false
    return all(k->typeof(left.statuses[k])===typeof(right.statuses[k]),keys(left.statuses)) &&
        all(k->typeof(left.references[k])===typeof(right.references[k]),keys(left.references))
end
function _coverage(simulation,program,arm,kind)
    policy=policies(arm)
    bounded=Main.BoundedPreparation.bounded_preparation_report(simulation)
    graph=Main.GraphRowProjection.graph_row_projection_report(simulation)
    typed_prep=Main.TypedOutputPreparation.typed_output_preparation_report(simulation)
    (bounded.scene_entries>0)===policy.preparation || error("Bounded prep arm contamination")
    graph.enabled===policy.preparation || error("Graph arm contamination")
    typed_prep.enabled===policy.preparation || error("Typed output prep arm contamination")
    if !policy.typed
        all(batch->batch isa PSE.CompiledExecutionBatch,simulation.execution_plan.batches) ||
            error("Ordinary control acquired a custom execution batch")
    end
    report=candidate_report(simulation,arm)
    entries=report===nothing ? 0 : report.batch_executions
    policy.typed && iszero(entries) && error("Typed arm executed no selected numerical batches")
    return (native_fields=0,driver_units=entries,native_driver_units=0,
        arm=arm,policy=policy,typed_program=report,bounded=bounded,graph=graph,
        typed_output_preparation=typed_prep,
        declaration_proofs_before=program.cache_before,
        declaration_proofs_after=_proof_report(program.proof_cache),
        scope=:original_scientific_models_and_ordinary_reference_storage,
        driver_units_kind=:actual_selected_batch_entries_not_prepared_or_inferred_work)
end

"""Small exact per-step PB/XP gates with independent ordinary controls.

This verifies complete state, history, RNG, numeric types, carrier identity
transitions, and actual numerical entry for newborn IDs. It makes no timing or
whole-feature-matrix claim.
"""
function cached_owner_downstream_checks(kind::Symbol;steps=2,nobjects=2,outputs=:all,
    arms=(:persistent,:proof_only,:owner_only,:combined),caches=new_caches())
    kind in (:pb,:xp) || throw(ArgumentError("Expected PB or XP"))
    config=H.construct_config(kind;steps,nobjects,outputs)
    Audit.verify_xp_source_audit()
    evidence=Any[]
    @testset "Cached proofs and cold owners preserve original downstream science" begin
        for arm in arms
            policy=policies(arm)
            left=Base.invokelatest(F.construct_fixture,kind,config)
            right=Base.invokelatest(F.construct_fixture,kind,config)
            reference=Base.invokelatest(_prepare,left,config,:ordinary_a)
            candidate=Base.invokelatest(_prepare,right,config,arm)
            program=Base.invokelatest(lower_candidate!,candidate,arm;caches,count_calls=true)
            old_left,old_right=F.identities(left.model),F.identities(right.model)
            @test _shape_parity(old_left,old_right)
            @test all(k->old_left.references[k]!==old_right.references[k],keys(old_left.references))
            @test isequal(_fingerprint(reference,kind),_fingerprint(candidate,kind))
            previous_entries=0
            previous_ids=Set(PSE.object_ids(right.model))
            per_step=Any[]
            for step in 1:steps
                Base.invokelatest(PSE.step!,reference)
                Base.invokelatest(PSE.step!,candidate)
                @test isequal(_fingerprint(reference,kind),_fingerprint(candidate,kind))
                next_left,next_right=F.identities(left.model),F.identities(right.model)
                @test _shape_parity(next_left,next_right)
                @test F.same_identity_transitions(old_left,old_right,next_left,next_right)
                old_left,old_right=next_left,next_right
                coverage=Base.invokelatest(_coverage,candidate,program,arm,kind)
                rows=candidate_regions(candidate,arm)
                new_ids=setdiff(Set(PSE.object_ids(right.model)),previous_ids)
                executed_newborn_ids=PSE.ObjectId[]
                if policy.typed
                    @test coverage.driver_units>previous_entries
                    previous_entries=coverage.driver_units
                    for region in rows
                        region.last_execution_model_revision==candidate.compiled.revision || continue
                        append!(executed_newborn_ids,intersect(region.last_execution_ids,collect(new_ids)))
                    end
                    if kind===:xp && !isempty(new_ids)
                        @test !isempty(executed_newborn_ids)
                    end
                end
                previous_ids=Set(PSE.object_ids(right.model))
                push!(per_step,(;step,coverage,region_count=length(rows),
                    new_ids=[id.value for id in new_ids],
                    typed_executed_newborn_ids=[id.value for id in unique(executed_newborn_ids)]))
            end
            work=CR.downstream_work_report(candidate,right.initial_ids)
            @test work==CR.downstream_work_report(reference,left.initial_ids)
            push!(evidence,(;arm,work,per_step,
                exact_state_history_rng_numeric_types_and_reference_transitions=true))
        end
    end
    return (;passed=true,kind,config,evidence,benchmark_claim=false,
        storage=:ordinary_references,source_audit=Audit.verify_xp_source_audit())
end

"""Register ordinary A/A and the 2×2 factors on a fixed preparation foundation.

`M.screen_case` constructs fresh scientific states, primes every arm outside its
sample timers, and alternates forward/reverse orders. Compilation and allocations
are recorded separately for construction, PSE preparation, backend lowering, and
execution. The ordinary plan's cost is charged before every typed installation.
The two cache arms have separate cache instances with equal capacity.
"""
function register_cached_owner_case!(name::Symbol,kind::Symbol;steps=2,nobjects=2,
    outputs=:none,arms=ARMS,replace=false,caches=new_caches())
    kind in (:pb,:xp) || error("Expected PB or XP")
    Audit.verify_xp_source_audit()
    all(arm->arm in arms,ARMS) || error("Include ordinary A/A, preparation-only, and all factorial arms")
    config=merge(H.construct_config(kind;steps,nobjects,outputs),
        (protocol=:cached_declaration_proofs_cold_owners_small_screen_v1,
        interpretation=:warm_fresh_scene_with_charged_ordinary_plan_then_typed_installation,
        statistical_unit=:one_independent_scene,storage=:ordinary_references,
        proof_cache_temperature=:primed_by_untimed_per_arm_warmup_not_disk_or_process_cold))
    return M.register_case!(name;config,replace,packages=(PSE,Main.NativePBDriver.PB,Main.NativeXPDriver.XPalm),
        variants=Tuple(M.VariantSpec(arm;driver=policies(arm).typed) for arm in arms),
        construct=(config,variant)->Base.invokelatest(F.construct_fixture,kind,config),
        prepare=(fixture,config,variant)->Base.invokelatest(_prepare,fixture,config,variant.name),
        lower=(simulation,fixture,config,variant)->Base.invokelatest(lower_candidate!,simulation,variant.name;caches),
        execute! = (simulation,program,fixture,config,variant)->Base.invokelatest(_advance!,simulation,config.steps),
        fingerprint=(simulation,fixture,config)->Base.invokelatest(_fingerprint,simulation,kind),
        coverage=(simulation,program,fixture,config,variant)->Base.invokelatest(_coverage,simulation,program,variant.name,kind),
        work=(simulation,fixture,config)->Base.invokelatest(CR.downstream_work_report,simulation,fixture.initial_ids))
end
screen_cached_owner(spec;repetitions=2,measure_retained=false)=Base.invokelatest(M.screen_case,spec;
    baseline=:ordinary_a,repetitions,measure_retained)

end # module
