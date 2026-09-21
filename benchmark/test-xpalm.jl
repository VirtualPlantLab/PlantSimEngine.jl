using BenchmarkTools
using CSV
using DataFrames
using Dates
using PlantSimEngine
using SHA
using TOML
using XPalm

const XPALM_REFERENCE_BASELINE = "v0.7.0-dev"
const XPALM_REFERENCE_SOURCE_COMMIT = "d4ded8891d03f85bb5691b89572a4e003ac6eb7a"

const XPALM_REFERENCE_BENCHMARK_VARIABLES = Dict{Symbol,Any}(
    :Scene => (:lai, :leaf_area, :aPPFD),
    :Plant => (
        :plant_age,
        :leaf_area,
        :aPPFD,
        :Rm,
        :carbon_assimilation,
        :phytomer_count,
        :biomass_bunch_harvested,
        :biomass_bunch_harvested_cum,
        :n_bunches_harvested,
        :n_bunches_harvested_cum,
        :biomass_oil_harvested,
        :biomass_oil_harvested_cum,
    ),
    :Soil => (:ftsw, :root_depth),
)

const XPALM_SMALL_BENCHMARK_VARIABLES = Dict{Symbol,Any}(
    :Scene => (:lai,),
)

function _xpalm_output_requests(model, vars)
    applications = PlantSimEngine.Diagnostics.explain_applications(model)
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
                    PlantSimEngine.Diagnostics.object_address(
                        row.applies_to,
                    ).scale == scale_symbol
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

function _xpalm_benchmark_meteo(; nsteps=nothing)
    meteo = CSV.read(
        joinpath(dirname(dirname(pathof(XPalm))), "0-data", "meteo.csv"),
        DataFrame,
    )
    :duration in propertynames(meteo) ||
        (meteo.duration = fill(Day(1), nrow(meteo)))
    isnothing(nsteps) && return meteo
    requested_steps = Int(nsteps)
    1 <= requested_steps <= nrow(meteo) || error(
        "XPalm benchmark `nsteps` must be between 1 and $(nrow(meteo)), got $(requested_steps).",
    )
    return meteo[1:requested_steps, :]
end

function xpalm_reference_model_create(; nsteps=nothing)
    meteo = _xpalm_benchmark_meteo(; nsteps=nsteps)
    palm = XPalm.Palm(
        initiation_age=0,
        parameters=XPalm.default_parameters(),
    )
    model = XPalm.xpalm_scene(palm; environment=meteo)
    return model, nrow(meteo)
end

function _xpalm_benchmark_scene(vars; nsteps=nothing)
    model, resolved_steps = xpalm_reference_model_create(; nsteps=nsteps)
    return model, _xpalm_output_requests(model, vars), resolved_steps
end

function xpalm_default_param_create(; nsteps=nothing)
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
    return _xpalm_benchmark_scene(vars; nsteps=nsteps)
end

function xpalm_small_param_create(; nsteps=nothing)
    return _xpalm_benchmark_scene(
        XPALM_SMALL_BENCHMARK_VARIABLES;
        nsteps=nsteps,
    )
end

function xpalm_reference_param_create(; nsteps=nothing)
    return _xpalm_benchmark_scene(
        XPALM_REFERENCE_BENCHMARK_VARIABLES;
        nsteps=nsteps,
    )
end

function xpalm_reference_end_to_end(; nsteps=nothing)
    meteo = _xpalm_benchmark_meteo(; nsteps=nsteps)
    return XPalm.xpalm(
        meteo,
        DataFrame;
        vars=XPALM_REFERENCE_BENCHMARK_VARIABLES,
        architecture=false,
        palm=XPalm.Palm(
            initiation_age=0,
            parameters=XPalm.default_parameters(),
        ),
    )
end

function xpalm_default_param_run(
    model,
    requests,
    nsteps;
    outputs=requests,
    performance=false,
)
    return PlantSimEngine.run!(
        model;
        steps=nsteps,
        outputs=outputs,
        performance=performance,
    )
end

function xpalm_reference_final_phytomer_count(simulation)
    plant = only(PlantSimEngine.model_objects(simulation.model; scale=:Plant))
    return plant.status.phytomer_count
end

function xpalm_reference_final_state(simulation)
    plant = only(PlantSimEngine.model_objects(simulation.model; scale=:Plant))
    scene = only(PlantSimEngine.model_objects(simulation.model; scale=:Scene))
    soil = only(PlantSimEngine.model_objects(simulation.model; scale=:Soil))
    return (
        current_step=PlantSimEngine.current_step(simulation),
        phytomer_count=plant.status.phytomer_count,
        lai=scene.status.lai,
        ftsw=soil.status.ftsw,
    )
end

function xpalm_reference_param_run(
    model,
    requests,
    nsteps;
    outputs=requests,
    performance=false,
)
    return xpalm_default_param_run(
        model,
        requests,
        nsteps;
        outputs=outputs,
        performance=performance,
    )
end

function xpalm_reference_full_cycle_expected_state(;
    xpalm_root=dirname(dirname(pathof(XPalm))),
)
    reference_dir = joinpath(
        xpalm_root, "test", "references", "regression", XPALM_REFERENCE_BASELINE,
    )
    metadata = TOML.parsefile(joinpath(reference_dir, "metadata.toml"))
    source = metadata["source"]
    inputs = metadata["inputs"]
    source["baseline_id"] == XPALM_REFERENCE_BASELINE ||
        error("XPalm benchmark reference baseline does not match $(XPALM_REFERENCE_BASELINE).")
    source["xpalm_commit"] == XPALM_REFERENCE_SOURCE_COMMIT ||
        error("XPalm benchmark reference source commit has changed; review its provenance.")
    source["parameter_source"] == "XPalm.default_parameters()" ||
        error("XPalm benchmark reference uses a different parameter scenario.")
    inputs["meteo_file"] == "0-data/meteo.csv" ||
        error("XPalm benchmark reference uses a different meteorology file.")
    inputs["nsteps"] == 4160 ||
        error("XPalm benchmark reference must cover the complete 4,160-day scenario.")

    meteo_path = joinpath(xpalm_root, "0-data", "meteo.csv")
    bytes2hex(SHA.sha256(read(meteo_path))) == inputs["meteo_sha256"] ||
        error("XPalm benchmark meteorology does not match the committed reference hash.")
    meteo = CSV.File(meteo_path)
    length(meteo) == inputs["nsteps"] ||
        error("XPalm benchmark meteorology length does not match the reference.")
    first(meteo).date == Date(inputs["start_date"]) &&
        last(meteo).date == Date(inputs["end_date"]) ||
        error("XPalm benchmark meteorology dates do not match the reference.")

    summary = only(CSV.File(joinpath(reference_dir, "summary.csv")))
    summary.nsteps == inputs["nsteps"] &&
        summary.start_date == Date(inputs["start_date"]) &&
        summary.end_date == Date(inputs["end_date"]) ||
        error("XPalm benchmark summary does not describe the reference meteorology.")
    isfinite(summary.final_lai) && isfinite(summary.final_ftsw) ||
        error("XPalm benchmark reference final state must be finite.")
    return (
        current_step=Int(summary.nsteps),
        phytomer_count=Int(summary.final_phytomer_count),
        lai=summary.final_lai,
        ftsw=summary.final_ftsw,
    )
end

function xpalm_reference_state_matches(
    state,
    expected=xpalm_reference_full_cycle_expected_state();
    atol=1.0e-8,
    rtol=1.0e-8,
)
    return state.current_step == expected.current_step &&
           state.phytomer_count == expected.phytomer_count &&
           isapprox(state.lai, expected.lai; atol=atol, rtol=rtol) &&
           isapprox(state.ftsw, expected.ftsw; atol=atol, rtol=rtol)
end

function xpalm_reference_high_level_final_state(outputs)
    plant = outputs[:Plant]
    scene = outputs[:Scene]
    soil = outputs[:Soil]
    return (
        current_step=nrow(plant),
        phytomer_count=last(plant.phytomer_count),
        lai=last(scene.lai),
        ftsw=last(soil.ftsw),
    )
end

function xpalm_reference_high_level_state_matches(
    outputs;
    expected=xpalm_reference_full_cycle_expected_state(),
    atol=1.0e-8,
    rtol=1.0e-8,
)
    return xpalm_reference_state_matches(
        xpalm_reference_high_level_final_state(outputs),
        expected;
        atol=atol,
        rtol=rtol,
    )
end

function xpalm_default_param_collect_outputs(simulation)
    return PlantSimEngine.collect_outputs(simulation; sink=DataFrame)
end
