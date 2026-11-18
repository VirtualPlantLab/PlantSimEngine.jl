module XPalmLifecycleApp

import CSV
import DataFrames: DataFrame, nrow
import Dates
import PlantSimEngine as PSE
import Tables
import XPalm
include("identity_preparation.jl")
include("witnesses.jl")

# The same requested variables as XPalm's official full-cycle regression.
const OUTPUT_VARIABLES = Dict{Symbol,Any}(
    :Scene => (:lai, :leaf_area, :aPPFD),
    :Plant => (
        :plant_age, :leaf_area, :aPPFD, :Rm, :carbon_assimilation,
        :phytomer_count, :biomass_bunch_harvested,
        :biomass_bunch_harvested_cum, :n_bunches_harvested,
        :n_bunches_harvested_cum, :biomass_oil_harvested,
        :biomass_oil_harvested_cum,
    ),
    :Soil => (:ftsw, :root_depth),
)
const DAILY_COLUMNS = (
    :date, :timestep, :plant_age, :phytomer_count,
    :scene_lai, :scene_leaf_area, :scene_aPPFD,
    :plant_leaf_area, :plant_aPPFD, :plant_Rm, :plant_carbon_assimilation,
    :biomass_bunch_harvested, :biomass_bunch_harvested_cum,
    :n_bunches_harvested, :n_bunches_harvested_cum,
    :biomass_oil_harvested, :biomass_oil_harvested_cum,
    :soil_ftsw, :soil_root_depth,
)

function prepare_application(; owners=nothing)
    meteo_path = joinpath(dirname(dirname(pathof(XPalm))), "0-data", "meteo.csv")
    _xpalm_preparation_phase!(:before_weather)
    meteo = CSV.read(meteo_path, DataFrame)
    _xpalm_preparation_phase!(:after_weather)
    :duration in propertynames(meteo) ||
        (meteo.duration = fill(Dates.Day(1), nrow(meteo)))
    nrow(meteo) == 4160 || error("The official XPalm forcing must contain 4160 days.")
    weather = Tables.rowtable(meteo)
    _xpalm_preparation_phase!(:before_Palm)
    palm = XPalm.Palm(initiation_age=0, parameters=XPalm.default_parameters())
    _xpalm_preparation_phase!(:after_Palm)
    _xpalm_preparation_phase!(:before_xpalm_scene)
    model = XPalm.xpalm_scene(palm; architecture=false, environment=weather)
    _xpalm_preparation_phase!(:after_xpalm_scene)
    _xpalm_preparation_phase!(:before_integer_domain)
    model = _prepare_xpalm_integer_id_domain(model)
    _xpalm_preparation_phase!(:after_integer_domain)
    requests = XPalm._output_requests(OUTPUT_VARIABLES)
    simulation = if isnothing(owners)
        _xpalm_preparation_phase!(:before_public_run0)
        PSE.run!(model; steps=0, outputs=requests)
    else
        _xpalm_preparation_phase!(:before_finite_prepare)
        prepared = PSE._prepare_simulation!(model; steps=0, outputs=requests,
            constants=PSE.Constants(), input_binding_storage=owners.input_prototype,
            status_view_schema=owners.view_schema, environment_schema=owners.environment_schema)
        _xpalm_preparation_phase!(:before_finite_continue0)
        PSE.continue!(prepared; steps=0)
    end
    _xpalm_preparation_phase!(:after_run0_branch)
    object_ids = (
        scene=only(PSE.object_ids(simulation.model; scale=:Scene)),
        plant=only(PSE.object_ids(simulation.model; scale=:Plant)),
        soil=only(PSE.object_ids(simulation.model; scale=:Soil)),
    )
    PSE.current_step(simulation) == 0 || error("Application preparation advanced the simulation.")
    return (; simulation, object_ids, date_labels=string.(meteo.date))
end

# Build-time preparation uses the real public XPalm and PSE entry points.
# No equations, alternative executor, guessed future batches, or model filtering.

function daily_snapshot(state=STATE)
    simulation = state.simulation
    day = PSE.current_step(simulation)
    1 <= day <= length(state.date_labels) || error("Daily output needs a completed timestep.")
    scene = PSE.model_status(simulation.model, state.object_ids.scene)
    plant = PSE.model_status(simulation.model, state.object_ids.plant)
    soil = PSE.model_status(simulation.model, state.object_ids.soil)
    return (
        date=state.date_labels[day], timestep=day,
        plant_age=plant.plant_age, phytomer_count=plant.phytomer_count,
        scene_lai=scene.lai, scene_leaf_area=scene.leaf_area, scene_aPPFD=scene.aPPFD,
        plant_leaf_area=plant.leaf_area, plant_aPPFD=plant.aPPFD,
        plant_Rm=plant.Rm, plant_carbon_assimilation=plant.carbon_assimilation,
        biomass_bunch_harvested=plant.biomass_bunch_harvested,
        biomass_bunch_harvested_cum=plant.biomass_bunch_harvested_cum,
        n_bunches_harvested=plant.n_bunches_harvested,
        n_bunches_harvested_cum=plant.n_bunches_harvested_cum,
        biomass_oil_harvested=plant.biomass_oil_harvested,
        biomass_oil_harvested_cum=plant.biomass_oil_harvested_cum,
        soil_ftsw=soil.ftsw, soil_root_depth=soil.root_depth,
    )
end

function write_daily_header(io)
    println(io, "date,timestep,plant_age,phytomer_count,scene_lai,scene_leaf_area,scene_aPPFD,plant_leaf_area,plant_aPPFD,plant_Rm,plant_carbon_assimilation,biomass_bunch_harvested,biomass_bunch_harvested_cum,n_bunches_harvested,n_bunches_harvested_cum,biomass_oil_harvested,biomass_oil_harvested_cum,soil_ftsw,soil_root_depth")
    return nothing
end

function write_daily_row(io, row)
    print(io, row.date)
    print(io, ',')
    print(io, row.timestep)
    print(io, ',')
    print(io, row.plant_age)
    print(io, ',')
    print(io, row.phytomer_count)
    print(io, ',')
    print(io, row.scene_lai)
    print(io, ',')
    print(io, row.scene_leaf_area)
    print(io, ',')
    print(io, row.scene_aPPFD)
    print(io, ',')
    print(io, row.plant_leaf_area)
    print(io, ',')
    print(io, row.plant_aPPFD)
    print(io, ',')
    print(io, row.plant_Rm)
    print(io, ',')
    print(io, row.plant_carbon_assimilation)
    print(io, ',')
    print(io, row.biomass_bunch_harvested)
    print(io, ',')
    print(io, row.biomass_bunch_harvested_cum)
    print(io, ',')
    print(io, row.n_bunches_harvested)
    print(io, ',')
    print(io, row.n_bunches_harvested_cum)
    print(io, ',')
    print(io, row.biomass_oil_harvested)
    print(io, ',')
    print(io, row.biomass_oil_harvested_cum)
    print(io, ',')
    print(io, row.soil_ftsw)
    print(io, ',')
    print(io, row.soil_root_depth)
    println(io)
    return nothing
end

# All report/preparation methods are defined before collecting real witnesses.
_xpalm_preparation_phase!(:before_prepare_function)
const STATE = prepare_witnessed_application()
_xpalm_preparation_phase!(:after_prepare_function)

function (@main)(args)
    length(args) <= 1 || return Cint(2)
    requested = isempty(args) ? 1 : tryparse(Int, only(args))
    requested isa Int || return Cint(2)
    0 <= requested <= length(STATE.date_labels) || return Cint(2)
    PSE.current_step(STATE.simulation) == 0 || return Cint(1)
    write_daily_header(Core.stdout)
    for _ in 1:requested
        PSE.step!(STATE.simulation)
        write_daily_row(Core.stdout, daily_snapshot())
    end
    return Cint(0)
end

end
