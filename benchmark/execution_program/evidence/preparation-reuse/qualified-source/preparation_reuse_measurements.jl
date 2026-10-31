module PreparationReuseMeasurements

using PlantSimEngine
const PSE=PlantSimEngine
const M=Main.NativeDownstreamMeasurements
const PB=Main.NativePBDriver
const XP=Main.NativeXPDriver
const CR=Main.CompiledRegionsExperiment

export PREPARATION_ARMS, prepare_arm, preparation_coverage,
    register_preparation_pb_case!, register_preparation_xp_case!

const PREPARATION_ARMS=(
    :reference_executor,:plan_view_reuse,:bounded_preparation,:combined)
_reuse()=getfield(Main,:PlanViewReuse)
_bounded()=getfield(Main,:BoundedPreparation)
_uses_reuse(arm)=arm in (:plan_view_reuse,:combined)
_uses_bounded(arm)=arm in (:bounded_preparation,:combined)

"""Enable independent per-model preparation policies before one common executor.

Every arm keeps ordinary canonical reference storage, scientific kernels,
sampling, scheduler and public continuation. No numerical backend is selected.
All construction, enablement and zero-step preparation belong to the normal
timed construction/preparation phases; no setup is moved outside those phases.
"""
function prepare_arm(model,arm::Symbol;steps=0,outputs=:none,
    constants=PSE.PlantMeteo.Constants(),performance=false)
    arm in PREPARATION_ARMS || throw(ArgumentError("Unknown preparation arm: $arm"))
    model.status_storage===nothing || throw(ArgumentError(
        "Preparation factorial must retain ordinary canonical reference storage"))
    _uses_reuse(arm) && _reuse().enable_plan_view_reuse!(model)
    _uses_bounded(arm) && _bounded().enable_bounded_preparation!(model)
    return PSE.run!(model;steps,outputs,constants,performance)
end

"""Require observed metadata work without claiming optimized numerical work."""
function preparation_coverage(simulation,arm::Symbol)
    arm in PREPARATION_ARMS || throw(ArgumentError("Unknown preparation arm: $arm"))
    simulation.model.status_storage===nothing || error("Preparation arm changed storage")
    reuse=_reuse().plan_view_reuse_report(simulation)
    bounded=_bounded().bounded_preparation_report(simulation)
    reused=reuse.recipe_hits+reuse.plain_preservations
    if _uses_reuse(arm)
        reused>0 || error("Reuse arm performed no metadata recipe reuse or plain preservation")
    else
        iszero(reused) || error("Ordinary reuse control was contaminated by reuse work")
    end
    if _uses_bounded(arm)
        bounded.scene_entries>0 && bounded.scenario_plans>0 &&
            bounded.metadata_symbol_tables>0 ||
            error("Bounded arm traversed no bounded scene/scenario/table factories")
    else
        iszero(bounded.scene_entries) && iszero(bounded.scenario_plans) ||
            error("Ordinary specialization control was contaminated by bounded factories")
    end
    return (native_fields=0,driver_units=0,native_driver_units=0,
        reused_metadata_operations=_uses_reuse(arm) ? reused : 0,
        bounded_scene_entries=_uses_bounded(arm) ? bounded.scene_entries : 0,
        reuse,bounded,
        qualification=:observed_preparation_metadata_work_with_ordinary_numerical_executor,
        scientific_kernels=:original,canonical_storage=:ordinary_references,
        numerical_driver_claim=false)
end

"""
Register four fresh PlantBiophysics scenarios; no checks or timings run here.
All 18 scientific fields/types and requested raw histories enter the fingerprint.
Cold comparison requires one fresh Kaimon process per arm; use measure_case's
first-use attestation. A warm screen is not a cold compilation measurement.
"""
function register_preparation_pb_case!(name::Symbol=:preparation_pb_small;
    nobjects::Int=2,steps::Int=2,outputs=:none,replace::Bool=false)
    config=(;nobjects,steps,outputs,package=:plantbiophysics,
        mechanism=:metadata_recipe_reuse_cross_bounded_preparation)
    return M.register_case!(name;config,replace,
        packages=(PSE,PB.PB,PB.PlantMeteo),
        variants=Tuple(M.VariantSpec(arm) for arm in PREPARATION_ARMS),
        construct=(config,variant)->begin
            fixture=PB.pb_native_fixture(;native=false,nobjects=config.nobjects,
                steps=config.steps)
            return (;fixture...,initial_ids=collect(PSE.object_ids(fixture.model)))
        end,
        prepare=(fixture,config,variant)->prepare_arm(fixture.model,variant.name;
            steps=0,outputs=config.outputs),
        lower=(simulation,fixture,config,variant)->nothing,
        execute! = (simulation,program,fixture,config,variant)->
            PSE.continue!(simulation;steps=config.steps),
        fingerprint=(simulation,fixture,config)->CR.portable_downstream_snapshot(simulation),
        coverage=(simulation,program,fixture,config,variant)->
            preparation_coverage(simulation,variant.name),
        work=(simulation,fixture,config)->
            CR.downstream_work_report(simulation,fixture.initial_ids))
end

"""
Register four independent XPalm growth scenarios with matched seed/forcing.
Weather file I/O occurs at registration, before any sample. Fixture/model/RNG
construction still occurs freshly inside each measured sample. Full normalized
scientific state/types/raw history and runtime topology enter the fingerprint.
The accelerated fixture screens computation; it is not biological validation.
"""
function register_preparation_xp_case!(name::Symbol=:preparation_xp_small;
    steps::Int=4,outputs=:none,emission_speed::Real=0.2,seed::Int=1,
    replace::Bool=false)
    base=XP.register_xp_case!(name;steps,outputs,emission_speed,seed,replace)
    return M.register_case!(name;config=base.config,replace=true,packages=base.packages,
        variants=Tuple(M.VariantSpec(arm) for arm in PREPARATION_ARMS),
        construct=base.construct,
        prepare=(fixture,config,variant)->prepare_arm(fixture.model,variant.name;
            steps=0,outputs=config.outputs),
        lower=(simulation,fixture,config,variant)->nothing,
        execute! = (simulation,program,fixture,config,variant)->
            PSE.continue!(simulation;steps=config.steps),
        fingerprint=(simulation,fixture,config)->(
            scientific=XP.xp_portable_snapshot(simulation),
            topology=sort!([(id=repr(object.id.value),parent=repr(object.parent),
                kind=repr(object.kind),scale=repr(object.scale),
                geometry=repr(PSE.geometry(object)))
                for object in PSE.model_objects(simulation.model)];by=row->row.id)),
        coverage=(simulation,program,fixture,config,variant)->
            preparation_coverage(simulation,variant.name),
        work=base.work)
end

end
