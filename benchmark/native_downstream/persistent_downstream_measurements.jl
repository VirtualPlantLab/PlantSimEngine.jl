module PersistentDownstreamMeasurements

using Test, PlantSimEngine
const PSE=PlantSimEngine
const F=Main.DirectPlannerFixtures
const H=Main.DirectPlannerMeasurements
const M=Main.NativeDownstreamMeasurements
const CR=Main.CompiledRegionsExperiment
const PT=Main.PersistentTightProgram
const Audit=Main.PersistentXPSourceAudit

export ARMS, policies, persistent_downstream_checks, register_persistent_case!, screen_persistent
const ARMS=(:ordinary_a,:ordinary_b,:preparation_only,:typed_only,:combined)
function policies(arm)
    arm in ARMS || throw(ArgumentError("Unknown persistent program arm"))
    return (preparation=arm in (:preparation_only,:combined),
        typed=arm in (:typed_only,:combined))
end

Base.@nospecializeinfer @noinline function _prepare(fixture,config,arm)
    @nospecialize fixture config
    policy=policies(arm)
    if policy.preparation
        Main.BoundedPreparation.enable_bounded_preparation!(fixture.model)
        Main.GraphRowProjection.enable_graph_row_projection!(fixture.model)
        Main.TypedOutputPreparation.enable_typed_output_preparation!(fixture.model)
    end
    return PSE.run!(fixture.model;steps=0,outputs=config.outputs)
end
Base.@nospecializeinfer @noinline function _lower(simulation,arm;count_calls=false)
    @nospecialize simulation
    if policies(arm).typed
        Base.invokelatest(PT.lower_persistent_tight!,simulation;count_calls)
    end
    return nothing
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
function _regions(simulation)
    return Base.invokelatest(PT.persistent_regions,simulation)
end
function _coverage(simulation,arm,kind)
    policy=policies(arm)
    bounded=Main.BoundedPreparation.bounded_preparation_report(simulation)
    graph=Main.GraphRowProjection.graph_row_projection_report(simulation)
    typed_prep=Main.TypedOutputPreparation.typed_output_preparation_report(simulation)
    (bounded.scene_entries>0)===policy.preparation || error("Bounded prep arm contamination")
    graph.enabled===policy.preparation || error("Graph arm contamination")
    typed_prep.enabled===policy.preparation || error("Typed output prep arm contamination")
    report=policy.typed ? Base.invokelatest(PT.persistent_tight_report,simulation) : nothing
    entries=report===nothing ? 0 : report.batch_executions
    policy.typed && iszero(entries) && error("Typed arm executed no selected numerical batches")
    return (native_fields=0,driver_units=entries,native_driver_units=0,
        arm,policy,typed_program=report,bounded,graph,typed_output_preparation=typed_prep,
        scope=:original_scientific_models_and_ordinary_reference_storage,
        driver_units_kind=:actual_selected_batch_entries_not_prepared_or_inferred_work)
end

"""Small per-step exact downstream gates, with fresh independent ordinary control.

The audit enables only six existing XP kernels. Every other model keeps normal
execution. Positive candidate entries are required after each scientific step;
newborn membership is checked in the live typed regions. This is not a timing.
"""
function persistent_downstream_checks(kind::Symbol;steps=2,nobjects=2,outputs=:all,
    arms=(:preparation_only,:typed_only,:combined))
    kind in (:pb,:xp) || throw(ArgumentError("Expected PB or XP"))
    config=H.construct_config(kind;steps,nobjects,outputs)
    Audit.verify_xp_source_audit()
    evidence=Any[]
    @testset "Persistent program preserves original downstream science" begin
        for arm in arms
            policy=policies(arm)
            left=Base.invokelatest(F.construct_fixture,kind,config)
            right=Base.invokelatest(F.construct_fixture,kind,config)
            reference=Base.invokelatest(_prepare,left,config,:ordinary_a)
            candidate=Base.invokelatest(_prepare,right,config,arm)
            Base.invokelatest(_lower,candidate,arm;count_calls=true)
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
                coverage=Base.invokelatest(_coverage,candidate,arm,kind)
                rows=policy.typed ? _regions(candidate) : ()
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
                push!(per_step,(step,coverage,region_count=length(rows),
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

"""Register five independent arms. Logical preparation builds ordinary plan first.

The typed arms then charge installation in backend_lowering, including the
ordinary plan constructed first. This conservative prototype separates phases
without pretending installation is free. A future direct installer can avoid
that extra plan only after lifecycle semantics are qualified.
"""
function register_persistent_case!(name::Symbol,kind::Symbol;steps=2,nobjects=4,outputs=:none,
    arms=ARMS,replace=false)
    kind in (:pb,:xp) || error("Expected PB or XP")
    Audit.verify_xp_source_audit()
    all(arm->arm in arms,ARMS) || error("Include ordinary A/A and all three candidates")
    config=merge(H.construct_config(kind;steps,nobjects,outputs),
        (protocol=:persistent_program_small_screen_v1,
        interpretation=:warm_fresh_scene_with_charged_ordinary_plan_then_typed_installation,
        statistical_unit=:one_independent_scene,storage=:ordinary_references))
    return M.register_case!(name;config,replace,packages=(PSE,Main.NativePBDriver.PB,Main.NativeXPDriver.XPalm),
        variants=Tuple(M.VariantSpec(arm;driver=policies(arm).typed) for arm in arms),
        construct=(config,variant)->Base.invokelatest(F.construct_fixture,kind,config),
        prepare=(fixture,config,variant)->Base.invokelatest(_prepare,fixture,config,variant.name),
        lower=(simulation,fixture,config,variant)->Base.invokelatest(_lower,simulation,variant.name),
        execute! = (simulation,program,fixture,config,variant)->Base.invokelatest(_advance!,simulation,config.steps),
        fingerprint=(simulation,fixture,config)->Base.invokelatest(_fingerprint,simulation,kind),
        coverage=(simulation,program,fixture,config,variant)->Base.invokelatest(_coverage,simulation,variant.name,kind),
        work=(simulation,fixture,config)->Base.invokelatest(CR.downstream_work_report,simulation,fixture.initial_ids))
end
screen_persistent(spec;repetitions=2)=Base.invokelatest(M.screen_case,spec;
    baseline=:ordinary_a,repetitions,measure_retained=false)

end # module
