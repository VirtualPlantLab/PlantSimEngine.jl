using BenchmarkTools
using CSV
using DataFrames
using Dates
using PlantSimEngine
using XPalm

function _xpalm_output_requests(model, vars)
    applications = explain_applications(model)
    requests = OutputRequest[]
    for (scale, variables) in pairs(vars)
        for variable in variables
            scale_symbol = Symbol(scale)
            variable_symbol = Symbol(variable)
            candidates = [
                row.application_id
                for row in applications
                if (
                    scale_symbol in row.target_scales ||
                    object_address(row.applies_to).scale == scale_symbol
                ) && variable_symbol in row.outputs
            ]
            isempty(candidates) && error(
                "No XPalm benchmark output publisher for `$(scale_symbol).$(variable_symbol)`.",
            )
            push!(
                requests,
                OutputRequest(
                    scale_symbol,
                    variable_symbol;
                    name=Symbol(scale, "__", variable),
                    application=last(candidates),
                ),
            )
        end
    end
    return requests
end

function xpalm_default_param_create()
    meteo = CSV.read(
        joinpath(dirname(dirname(pathof(XPalm))), "0-data", "meteo.csv"),
        DataFrame,
    )
    :duration in propertynames(meteo) ||
        (meteo.duration = fill(Day(1), nrow(meteo)))

    vars = Dict{Symbol,Any}(
        :Scene => (:lai,),
        :Leaf => (
            :Rm,
            :potential_area,
            :TT_since_init,
            :biomass,
            :carbon_demand,
        ),
        :Male => (:Rm,),
    )
    palm = XPalm.Palm(
        initiation_age=0,
        parameters=XPalm.default_parameters(),
    )
    model = XPalm.xpalm_scene(palm; environment=meteo)
    return model, _xpalm_output_requests(model, vars), nrow(meteo)
end

function xpalm_default_param_run(model, requests, nsteps)
    return PlantSimEngine.run!(
        model;
        steps=nsteps,
        outputs=requests,
    )
end

function xpalm_default_param_collect_outputs(simulation)
    return PlantSimEngine.collect_outputs(simulation; sink=DataFrame)
end
