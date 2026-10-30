# Downstream fixtures and explicit author audits. This file is included inside
# CompiledRegionsExperiment, after the region/call compiler definitions.
# Package sources are read-only; all arms execute their original methods.

using Dates
using Random
using CSV
using DataFrames
using PlantMeteo
using PlantBiophysics
using XPalm

const PB = PlantBiophysics

"""
    pb_many_fixture(; nobjects=32, steps=8)

One registry containing N independent gas-exchange objects. Monteith, Fvcb and
Medlyn are real package models with their original model-level same-object call
declarations. Neither the compiler nor the selection predicate uses scale names.
"""
function pb_many_fixture(; nobjects::Int=32, steps::Int=8)
    nobjects > 0 || throw(ArgumentError("nobjects must be positive"))
    steps > 0 || throw(ArgumentError("steps must be positive"))
    objects = [PSE.Object(index; kind=:gas_exchange_unit, scale=:diagnostic_unit,
        status=PSE.Status(Ra_SW_f=150.0 + mod(index, 7), sky_fraction=0.8,
            aPPFD=(150.0 + mod(index, 7)) * 0.48 * 4.57, d=0.03))
        for index in 1:nobjects]
    # Variation is deterministic and mild: it is not a calibration dataset.
    forcing = PlantMeteo.Weather([
        PlantMeteo.Atmosphere(T=24.0 + 0.25 * mod(step - 1, 5),
            Wind=1.5, P=101.325, Rh=0.65, Cₐ=410.0, duration=Hour(1))
        for step in 1:steps
    ])
    return PSE.CompositeModel(objects...;
        applications=(
            PSE.ModelSpec(PB.Monteith(); name=:energy,
                on=PSE.Many(kind=:gas_exchange_unit), every=Hour(1)),
            PSE.ModelSpec(PB.Fvcb(); name=:photosynthesis,
                on=PSE.Many(kind=:gas_exchange_unit), every=Hour(1)),
            PSE.ModelSpec(PB.Medlyn(0.03, 12.0); name=:stomata,
                on=PSE.Many(kind=:gas_exchange_unit), every=Hour(1)),
        ), environment=forcing)
end

function _xpalm_fixture_weather(steps::Int)
    steps > 0 || throw(ArgumentError("steps must be positive"))
    path = joinpath(pkgdir(XPalm), "0-data", "meteo.csv")
    table = CSV.read(path, DataFrame; limit=steps)
    nrow(table) == steps || error("XPalm weather has fewer rows than requested")
    :duration in propertynames(table) || (table.duration = fill(Day(1), steps))
    return table
end

"""
    xpalm_growth_fixture(; steps=4, emission_speed=0.2, seed=1, weather=nothing)

Use the full XPalm scene and original models, with a documented diagnostic
parameter change: both phyllochron speeds are 0.2 phytomer per degree-day.
This makes a short run exercise real PhytomerEmission, add_organ!, initializers,
binding refresh, new targets, and later same-step applications. All other model
parameters retain XPalm defaults. This is a computational growth fixture, not a
calibrated biological scenario. Each arm receives the identical builder/seed.
"""
function xpalm_growth_fixture(; steps::Int=4, emission_speed::Real=0.2,
    seed::Int=1, weather=nothing)
    steps > 0 || throw(ArgumentError("steps must be positive"))
    isfinite(emission_speed) && emission_speed > 0 ||
        throw(ArgumentError("emission_speed must be finite and positive"))
    Random.seed!(seed)
    parameters = XPalm.default_parameters()
    parameters["phyllochron"]["production_speed_initial"] = Float64(emission_speed)
    parameters["phyllochron"]["production_speed_mature"] = Float64(emission_speed)
    palm = XPalm.Palm(initiation_age=0, parameters=parameters)
    forcing = isnothing(weather) ? _xpalm_fixture_weather(steps) : copy(weather)
    return XPalm.xpalm_scene(palm; environment=forcing, architecture=false)
end

"""Read optional fixture data once, outside construction/runtime timings."""
function downstream_fixture(kind::Symbol; nobjects::Int=32, steps::Int=4,
    emission_speed::Real=0.2, seed::Int=1)
    if kind === :plantbiophysics
        builder = () -> pb_many_fixture(; nobjects, steps)
        return (; kind, builder, steps,
            metadata=(package_root=pkgdir(PB), package_version=string(Base.pkgversion(PB)),
                nobjects, registry_count=1, forcing=:deterministic_mild_hourly,
                scientific_models=(:Monteith, :Fvcb, :Medlyn)))
    elseif kind === :xpalm
        weather = _xpalm_fixture_weather(steps)
        builder = () -> xpalm_growth_fixture(; steps, emission_speed, seed, weather)
        return (; kind, builder, steps,
            metadata=(package_root=pkgdir(XPalm), package_version=string(Base.pkgversion(XPalm)),
                weather_path=joinpath(pkgdir(XPalm), "0-data", "meteo.csv"),
                seed, initiation_age=0, architecture=false,
                parameter_changes=(phyllochron_production_speed_initial=Float64(emission_speed),
                    phyllochron_production_speed_mature=Float64(emission_speed)),
                interpretation=:diagnostic_accelerated_growth_not_calibration))
    end
    throw(ArgumentError("Unknown downstream fixture $(kind)"))
end

# Exact concrete numeric types used by the default downstream fixtures. The
# compiler has no package-dependent eligibility branches. A model whose port
# values/parameters violate the compiler's scalar/proof conditions still falls
# back even when its kernel belongs to this audited list.
const XPALM_LOCAL_PORT_AUDIT = (
    (model=XPalm.DailyPlantAgeModel(), source="plant/plant_age/palm_age_increment.jl",
        evidence="Reads/writes declared plant_age only; no context"),
    (model=XPalm.DailyDegreeDays(), source="meteo/thermal_time.jl",
        evidence="Declared TEff/TT_since_init and scalar Tmin/Tmax; default valid temperature parameters"),
    (model=XPalm.DailyDegreeDaysSinceInit(), source="meteo/thermal_time.jl",
        evidence="Declared TEff input and TT_since_init output; readonly One input may be shared"),
    (model=XPalm.DegreeDaysFTSW(), source="meteo/thermal_time_ftsw.jl",
        evidence="Declared ftsw/TEff/TT_since_init and Tmin/Tmax; valid default parameters"),
    (model=XPalm.PhyllochronModel(), source="plant/phytomer/leaves/phyllochron.jl",
        evidence="Declared age/TEff inputs and scalar emergence/prod/pulse outputs; emission itself stays ordered"),
    (model=XPalm.FinalPotentialAreaModel(), source="plant/phytomer/leaves/final_potential_area.jl",
        evidence="Declared initiation_age/final_potential_area; scalar age_relative_value helper"),
    (model=XPalm.PotentialAreaModel(337.5, 100.0), source="plant/phytomer/leaves/potential_area.jl",
        evidence="Declared potential-area, increment and maturity fields only; valid positive slope"),
    (model=XPalm.LeafCarbonDemandModelPotentialArea(), source="plant/phytomer/leaves/carbon_demand.jl",
        evidence="Declared state/increment input and demand output; valid nonzero contribution parameter"),
    (model=XPalm.LeafBiomass(), source="plant/phytomer/leaves/biomass.jl",
        evidence="Declared allocation input and biomass/compartment outputs; scalar parameters"),
    (model=XPalm.LeafAreaModel(80.0, 0.30, 0.02), source="plant/phytomer/leaves/leaf_area.jl",
        evidence="Declared biomass input and area output; valid positive LMA"),
    (model=XPalm.PotentialInternodeDimensionModel(), source="plant/phytomer/internode/potential_dimensions.jl",
        evidence="Declared thermal-time/final dimensions and potential dimension outputs"),
    (model=XPalm.InternodeCarbonDemandModel(), source="plant/phytomer/internode/carbon_demand.jl",
        evidence="Declared dimensions/potential-volume/demand only; scalar arithmetic"),
    (model=XPalm.InternodeBiomass(), source="plant/phytomer/internode/biomass.jl",
        evidence="Declared allocation and biomass only; valid construction cost"),
    (model=XPalm.InternodeDimensionModel(), source="plant/phytomer/internode/actual_dimension.jl",
        evidence="Declared potential dimensions/biomass and radius/height; guarded positive-volume cube root"),
    (model=XPalm.RootGrowthFTSW(ini_root_depth=100.0), source="plant/roots/root_growth.jl",
        evidence="Declared ftsw/TEff/soil_depth/root_depth; valid positive stress threshold"),
    (model=XPalm.RUE_FTSW(4.8, 0.3), source="plant/carbon_assimilation/rue_ftsw.jl",
        evidence="Declared aPPFD/ftsw/assimilation plus readonly scalar constant J_to_umol"),
    (model=XPalm.RmQ10FixedN(2.1, 0.0022, 25.0, 1.0), source="plant/respiration/maintenance/Q10.jl",
        evidence="Declared biomass/Rm plus Tmin/Tmax; valid positive Q10; temporal policy remains a boundary"),
    (model=XPalm.PotentialReserveInternode(), source="plant/reserves/potential_reserve_internode.jl",
        evidence="Declared biomass/reserve/potential_reserve only; no context"),
    (model=XPalm.ConstantRUEModel(4.8), source="plant/carbon_assimilation/rue.jl",
        evidence="Declared aPPFD/assimilation plus scalar constant J_to_umol"),
    (model=XPalm.InitiationAgeFromPlantAge(), source="plant/plant_age/initiation_age.jl",
        evidence="Copies declared scalar age input to declared initiation output; call control remains parent-owned"),
)

for row in XPALM_LOCAL_PORT_AUDIT
    T = typeof(row.model)
    @eval region_effects(::Type{$T}) = :local_ports
end

# The prior control kernel already uses only its declared scalar ports. Keep
# the stronger promise specific to the new compiler rather than changing the
# old prototype's :local contract or its full-status lowering behavior.
region_effects(::Type{<:GP.ChainStage}) = :local_ports

const PB_STABLE_CALL_AUDIT = (
    (model=PB.Monteith(), source="processes/energy/Monteith.jl",
        evidence="Original controller loops call photosynthesis with sampled_environment and publish=false; no structural edits"),
    (model=PB.Fvcb(), source="processes/photosynthesis/FvCB.jl",
        evidence="Original call_model/gs_coupling and stomatal run_call share trial status; no structural edits"),
    (model=PB.Medlyn(0.03, 12.0), source="processes/conductances/stomatal/stomatal_conductance.jl",
        evidence="Original scalar gs_closure/conductance method; no structural edits"),
)

for row in PB_STABLE_CALL_AUDIT
    T = typeof(row.model)
    @eval resolved_call_effects(::Type{$T}) = :stable_calls
end

function downstream_audit_report()
    return (
        local_ports=[(type=string(typeof(row.model)), source=row.source, evidence=row.evidence)
            for row in XPALM_LOCAL_PORT_AUDIT],
        stable_calls=[(type=string(typeof(row.model)), source=row.source, evidence=row.evidence)
            for row in PB_STABLE_CALL_AUDIT],
        excluded=(
            (type=:PotentialReserveLeaf, reason=:reads_undeclared_state),
            (type=:SexDetermination, reason=:mutable_random_generator),
            (type=:AbortionRate, reason=:mutable_random_generator),
            (type=:PhytomerEmission, reason=:lifecycle_and_context_effects),
            (type=:ReproductiveOrganEmission, reason=:lifecycle_and_context_effects),
            (type=:InfloStateModel, reason=:cross_object_context_writes),
            (type=:LeafStateModel, reason=:cross_object_and_many_reads),
            (type=:OrgansCarbonAllocationModel, reason=:distributed_outputs_and_many_inputs),
        ),
        qualification=:source_audit_for_default_diagnostic_inputs_not_global_purity_proof,
        trait_function=:CompiledRegionsExperiment_region_effects,
    )
end

function downstream_fingerprint(simulation)
    states = Dict(object.id => deepcopy(PSE.final_state(simulation, object.id))
        for object in PSE.model_objects(PSE.runtime_model(simulation)))
    histories = Dict(key => deepcopy(collect(stream))
        for (key, stream) in pairs(PSE.outputs(simulation)))
    return (; step=PSE.current_step(simulation), states, histories)
end

function downstream_work_report(simulation, initial_ids)
    model = PSE.runtime_model(simulation)
    objects = collect(PSE.model_objects(model))
    final_ids = Set(object.id for object in objects)
    added = sort!([id.value for id in setdiff(final_ids, Set(initial_ids))]; by=repr)
    scales = Dict{Symbol,Int}()
    for object in objects
        scale = isnothing(object.scale) ? :none : Symbol(object.scale)
        scales[scale] = get(scales, scale, 0) + 1
    end
    return (steps=PSE.current_step(simulation), objects=length(objects), added_ids=added,
        objects_by_scale=scales, streams=length(PSE.outputs(simulation)))
end
