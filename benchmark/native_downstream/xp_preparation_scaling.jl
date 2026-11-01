module XPPreparationScaling

using Random, SHA, PlantSimEngine
const PSE=PlantSimEngine
const XP=Main.NativeXPDriver.XPalm
const CR=Main.CompiledRegionsExperiment
const F=Main.DirectPlannerFixtures
const M=Main.NativeDownstreamMeasurements
const D=Main.XPDispatchRefreshMeasurements
export XP_SCALING_ARMS, xp_scaling_config, xp_scaling_ladder,
    construct_xp_scaling_fixture, xp_scaling_observation, xp_scaling_work,
    xp_scaling_coverage, prepare_xp_scaling, register_xp_preparation_scaling_case!,
    screen_xp_preparation_scaling

const XP_SCALING_ARMS=(:ordinary_a,:ordinary_b,:bounded_graph,:typed_graph)
const XP_OPTIONAL_ARMS=(:typed_only,)
const PROFILES=(:accelerated,:package_defaults)
const DAYS=(2,12,32,64,128)
_dispatch_arm(arm)=arm===:typed_only ? :typed_barrier : arm
function _arms(arms)
    names=Tuple(Symbol(arm) for arm in arms)
    all(arm->arm in (XP_SCALING_ARMS...,XP_OPTIONAL_ARMS...),names) ||
        throw(ArgumentError("Unknown XP scaling arm"))
    length(unique(names))==length(names) || throw(ArgumentError("Duplicate XP scaling arm"))
    return names
end

function xp_scaling_config(;days::Int=2,profile::Symbol=:accelerated,
    seed::Int=1,outputs=:none,allow_large::Bool=false)
    days in DAYS || throw(ArgumentError("Choose a staged trajectory: $DAYS"))
    profile in PROFILES || throw(ArgumentError("Choose :accelerated or :package_defaults"))
    days<=32 || allow_large || throw(ArgumentError(
        "64/128 days require allow_large=true after a qualified smaller trajectory"))
    return (;kind=:xp,days,steps=days,profile,seed,outputs,allow_large,
        scene_count=1,palm_count=1,initiation_age=0,architecture=false,
        accelerated_emission_speed=profile===:accelerated ? 0.2 : nothing,
        fixture_role=profile===:accelerated ? :diagnostic_accelerated_growth :
            :unchanged_package_parameter_defaults,
        initial_scene=:one_original_Palm_constructor_without_synthetic_organs,
        scaling_axis=:duration_and_realized_organs_in_one_original_scene,
        numerical_executor=:ordinary,canonical_storage=:ordinary_references,
        measurement_protocol=:xp_preparation_single_trajectory_v1)
end

"""Requests and stopping budgets, never measurements or automatic scale approval."""
xp_scaling_ladder()=(
    (days=2,role=:initial_exact_gate,profiles=PROFILES,warm_cycles=0,
        proposed_wall_budget_seconds=60),
    (days=12,role=:small_warm_screen,profiles=PROFILES,warm_cycles=4,
        proposed_wall_budget_seconds=120),
    (days=32,role=:medium_single_trajectory,profiles=PROFILES,warm_cycles=4,
        proposed_wall_budget_seconds=180),
    (days=64,role=:conditional_larger,profiles=PROFILES,warm_cycles=4,
        proposed_wall_budget_seconds=240),
    (days=128,role=:conditional_larger,profiles=PROFILES,warm_cycles=4,
        proposed_wall_budget_seconds=300))

"""Original XPalm construction, one live palm and one canonical object registry.

The accelerated cohort changes only the two phyllochron speeds to 0.2, matching
prior diagnostic fixtures. The package-default cohort changes no parameter.
Both explicitly use initiation_age=0 and architecture=false; neither prebuilds
future organs or claims calibrated biology. Real growth determines scene size.
"""
Base.@nospecializeinfer @noinline function construct_xp_scaling_fixture(config;weather=nothing)
    @nospecialize config weather
    Random.seed!(config.seed)
    parameters=XP.default_parameters()
    before=(initial=parameters["phyllochron"]["production_speed_initial"],
        mature=parameters["phyllochron"]["production_speed_mature"])
    if config.profile===:accelerated
        parameters["phyllochron"]["production_speed_initial"]=0.2
        parameters["phyllochron"]["production_speed_mature"]=0.2
    end
    after=(initial=parameters["phyllochron"]["production_speed_initial"],
        mature=parameters["phyllochron"]["production_speed_mature"])
    palm=XP.Palm(initiation_age=config.initiation_age,parameters=parameters)
    forcing=weather===nothing ? CR._xpalm_fixture_weather(config.days) : copy(weather)
    size(forcing,1)==config.days || error("Weather length differs from trajectory")
    model=XP.xpalm_scene(palm;environment=forcing,architecture=config.architecture)
    initial_ids=collect(PSE.object_ids(model))
    return (;model,initial_ids,initial_object_count=length(initial_ids),package=:xp,
        parameter_provenance=(profile=config.profile,phyllochron_before=before,
            phyllochron_effective=after,parameter_changes=config.profile===:accelerated ?
                (:production_speed_initial,:production_speed_mature) : (),
            initiation_age=config.initiation_age,architecture=config.architecture),
        scene_count=1,palm_count=1)
end

Base.@nospecializeinfer @noinline function prepare_xp_scaling(model,arm::Symbol;outputs=:none)
    @nospecialize model outputs
    _arms((arm,))
    return Base.invokelatest(D.prepare_dispatch_refresh,model,_dispatch_arm(arm);outputs)
end
Base.@nospecializeinfer @noinline function xp_scaling_observation(simulation)
    @nospecialize simulation
    return (;state=Base.invokelatest(F.snapshot,simulation,:xp),
        scientific_rngs=Base.invokelatest(F.scientific_rngs,simulation.model))
end
Base.@nospecializeinfer @noinline function xp_scaling_work(simulation,fixture,config)
    @nospecialize simulation fixture config
    actual=Base.invokelatest(CR.downstream_work_report,simulation,fixture.initial_ids)
    actual.steps==config.days || error("Trajectory did not advance all requested days")
    return merge(actual,(;initial_objects=fixture.initial_object_count,
        final_objects=actual.objects,added_objects=length(actual.added_ids),
        scene_count=1,palm_count=1,profile=config.profile,
        parameter_provenance=fixture.parameter_provenance,
        actual_organ_counts=actual.objects_by_scale,
        scaling_axis=config.scaling_axis,independent_replicas_per_sample=1,
        growth_qualification=isempty(actual.added_ids) ? :no_observed_newborns :
            :original_scientific_growth_observed))
end
Base.@nospecializeinfer @noinline function xp_scaling_coverage(simulation,fixture,config,arm)
    @nospecialize simulation fixture config
    require_growth=config.profile===:accelerated
    base=Base.invokelatest(D.dispatch_refresh_coverage,simulation,_dispatch_arm(arm),:xp;
        require_growth)
    actual=Base.invokelatest(CR.downstream_work_report,simulation,fixture.initial_ids)
    require_growth && isempty(actual.added_ids) && error("Accelerated trajectory observed no real growth")
    return merge(base,(;trajectory_arm=arm,scene_count=1,palm_count=1,
        profile=config.profile,newborn_count=length(actual.added_ids),
        newborn_coverage_required=require_growth,
        newborn_qualification=isempty(actual.added_ids) ? :no_newborn_credit :
            :actual_added_object_ids,metadata_work_is_not_kernel_work=true))
end

"""Register one increasing-size trajectory, never an aggregate of replicas.

Weather file reading/hash occurs at registration. Every timed construction uses
its own copied rows and fresh model/RNG state. The standard measurement harness
charges construction, all preparation, and original ordinary execution; exact
state/history/RNG diagnostics occur after timing. For a cold sample use
M.measure_case(spec,arm;temperature=:first_use,freshness=...) in a fresh worker.
"""
Base.@nospecializeinfer @noinline function register_xp_preparation_scaling_case!(
    name::Symbol=:xp_preparation_trajectory;days::Int=2,profile::Symbol=:accelerated,
    arms=XP_SCALING_ARMS,outputs=:none,seed::Int=1,allow_large::Bool=false,
    replace::Bool=false)
    names=_arms(arms)
    all(arm->arm in names,XP_SCALING_ARMS) || throw(ArgumentError(
        "Include both identical ordinary A/A controls, bounded_graph and typed_graph"))
    weather=CR._xpalm_fixture_weather(days)
    weather_path=joinpath(pkgdir(XP),"0-data","meteo.csv")
    config=merge(xp_scaling_config(;days,profile,seed,outputs,allow_large),
        (;placebo_pair=(:ordinary_a,:ordinary_b),
            forcing=(path=weather_path,sha256=bytes2hex(sha256(read(weather_path))),
                rows=days,source=:first_original_daily_rows,copy_per_construction=true),
            dispatch_policies_by_arm=Dict(arm=>D.dispatch_refresh_policies(_dispatch_arm(arm)) for arm in names),
            statistical_unit=:one_fresh_single_scene_trajectory,
            complete_cost_scope=:construction_enablement_all_preparation_and_execution,
            forcing_file_read_timing=:excluded_at_registration))
    return M.register_case!(name;config,replace,packages=(PSE,XP),
        variants=Tuple(M.VariantSpec(arm) for arm in names),
        construct=(config,variant)->Base.invokelatest(construct_xp_scaling_fixture,config;weather),
        prepare=(fixture,config,variant)->Base.invokelatest(prepare_xp_scaling,
            fixture.model,variant.name;outputs=config.outputs),
        lower=(simulation,fixture,config,variant)->nothing,
        execute! = (simulation,program,fixture,config,variant)->
            Base.invokelatest(PSE.continue!,simulation;steps=config.days),
        fingerprint=(simulation,fixture,config)->Base.invokelatest(xp_scaling_observation,simulation),
        coverage=(simulation,program,fixture,config,variant)->
            Base.invokelatest(xp_scaling_coverage,simulation,fixture,config,variant.name),
        work=(simulation,fixture,config)->Base.invokelatest(xp_scaling_work,simulation,fixture,config))
end
function screen_xp_preparation_scaling(spec;repetitions::Int=4,measure_retained=false)
    return Base.invokelatest(M.screen_case,spec;baseline=:ordinary_a,repetitions,measure_retained)
end

end # module
