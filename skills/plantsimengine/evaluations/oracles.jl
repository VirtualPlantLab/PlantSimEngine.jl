using Dates
using PlantSimEngine
using PlantSimEngine.Authoring

const ORACLE_SKILL_ROOT = realpath(joinpath(@__DIR__, ".."))
const ORACLE_ASSET_ROOT = joinpath(ORACLE_SKILL_ROOT, "assets")
const ORACLE_FIXTURE_ROOT = joinpath(@__DIR__, "fixtures")

include(joinpath(ORACLE_ASSET_ROOT, "minimal-model.jl"))
include(joinpath(ORACLE_ASSET_ROOT, "alternative-model.jl"))
include(joinpath(ORACLE_ASSET_ROOT, "adapter-model.jl"))
include(joinpath(ORACLE_ASSET_ROOT, "coupling-patterns.jl"))
include(joinpath(ORACLE_ASSET_ROOT, "runtime-patterns.jl"))
include(joinpath(ORACLE_ASSET_ROOT, "lifecycle-output.jl"))
include(joinpath(
    ORACLE_FIXTURE_ROOT,
    "generic-julia",
    "src",
    "GenericJuliaFixture.jl",
))
include(joinpath(
    ORACLE_FIXTURE_ROOT,
    "two-process-package",
    "src",
    "TwoProcessFixture.jl",
))

module MissingEnvironmentExample

using Dates
using PlantSimEngine

export MissingCO2Probe, missing_environment_scenario, CO2_CONTRACT

PlantSimEngine.@process "skill_evaluation_missing_environment" verbose=false

const CO2_CONTRACT = VariableContract(
    unit=:micromol_per_mol,
    basis=:air,
    temporal=:instantaneous,
    aggregation=:state,
    extent=:intensive,
)

struct MissingCO2Probe <: AbstractSkill_Evaluation_Missing_EnvironmentModel end

PlantSimEngine.inputs_(::MissingCO2Probe) = NamedTuple()
PlantSimEngine.outputs_(::MissingCO2Probe) = (co2_seen=0.0,)
PlantSimEngine.environment_inputs_(::MissingCO2Probe) = (CO2=0.0,)
PlantSimEngine.environment_outputs_(::MissingCO2Probe) = NamedTuple()
PlantSimEngine.variable_contracts_(::MissingCO2Probe) = (
    CO2=CO2_CONTRACT,
    co2_seen=CO2_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::MissingCO2Probe) = (
    hypothesis="The probe copies a required atmospheric CO2 driver.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)

function PlantSimEngine.run!(
    ::MissingCO2Probe,
    status,
    environment,
    constants,
    context,
)
    status.co2_seen = environment.CO2
    return nothing
end

function missing_environment_scenario()
    return CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(:leaf; scale=:Leaf, kind=:leaf, parent=:scene);
        applications=(
            ModelSpec(
                MissingCO2Probe();
                name=:missing_co2_probe,
                on=One(scale=:Leaf),
                environment=Environment(provider=:global),
            ),
        ),
        environment=(T=20.0, duration=Hour(1)),
    )
end

end # module MissingEnvironmentExample

function _workspace_direct_trigger_oracle()
    path = joinpath(ORACLE_ASSET_ROOT, "minimal-model.jl")
    source = read(path, String)
    return (
        passed=isfile(path) && occursin("VariableContract", source),
        fixture=path,
        evidence=:workspace_precondition,
    )
end

function _workspace_plantsimengine_dependency_oracle()
    path = joinpath(ORACLE_FIXTURE_ROOT, "two-process-package", "Project.toml")
    source = read(path, String)
    return (
        passed=isfile(path) && occursin("PlantSimEngine", source),
        fixture=path,
        evidence=:workspace_precondition,
    )
end

function _workspace_incomplete_request_oracle()
    project = _workspace_plantsimengine_dependency_oracle()
    prompt = evaluation_case(:incomplete_process_request).prompt
    return (
        passed=project.passed && !occursin("unit", lowercase(prompt)),
        fixture=project.fixture,
        evidence=:workspace_precondition,
    )
end

function _workspace_generic_julia_oracle()
    path = joinpath(
        ORACLE_FIXTURE_ROOT,
        "generic-julia",
        "src",
        "GenericJuliaFixture.jl",
    )
    source = read(path, String)
    sorted = GenericJuliaFixture.stable_merge_sort([3, 1, 2, 1])
    return (
        passed=sorted == [1, 1, 2, 3] && !occursin("PlantSimEngine", source),
        fixture=path,
        evidence=:workspace_precondition,
    )
end

function _workspace_stale_environment_oracle()
    root = joinpath(ORACLE_FIXTURE_ROOT, "stale-environment")
    tutorial = read(joinpath(root, "OLD_TUTORIAL.md"), String)
    loaded = read(joinpath(root, "loaded-package.toml"), String)
    return (
        passed=occursin("0.14", tutorial) &&
               occursin("0.15.0", loaded) &&
               occursin("stale-copy", loaded),
        fixture=root,
        evidence=:workspace_precondition,
    )
end

function _existing_process_model_oracle()
    model = MinimalModelExample.RadiationUseEfficiency(1.5f0)
    status = MinimalModelExample.direct_example(Float32)
    scenario = MinimalModelExample.single_object_scenario(Float32)
    report = validate_scenario(scenario; strict=true)
    simulation = run!(scenario; steps=1, outputs=:none)
    return (
        passed=validate_model(model; strict=true).valid &&
               status.biomass_increment === 15.0f0 &&
               report.valid &&
               final_state(simulation).biomass_increment === 15.0f0,
        evidence=:executable_model,
    )
end

function _drop_in_alternative_oracle()
    linear = AlternativeModelExample.LinearCarbonGain(1.25f0)
    saturating = AlternativeModelExample.SaturatingCarbonGain(10.0f0, 5.0f0)
    comparison = compare_models(linear, saturating)
    return (
        passed=comparison.same_process &&
               comparison.override_compatible &&
               !comparison.requires_binding_changes &&
               comparison.compatibility == :direct_override,
        evidence=:executable_model,
    )
end

function _same_process_binding_changes_oracle()
    linear = AlternativeModelExample.LinearCarbonGain(1.25f0)
    limited = AlternativeModelExample.WaterLimitedCarbonGain(1.25f0)
    comparison = compare_models(linear, limited)
    return (
        passed=comparison.same_process &&
               !comparison.override_compatible &&
               comparison.requires_binding_changes &&
               comparison.requires_reconfiguration,
        evidence=:executable_model,
    )
end

function _many_subtree_coupling_oracle()
    scenario = CouplingPatternsExample.coupling_scenario(Float32)
    report = validate_scenario(scenario; strict=true)
    bindings = Diagnostics.explain_bindings(scenario)
    simulation = run!(scenario; steps=1, outputs=:none)
    plant = final_state(simulation, One(scale=:Plant))
    return (
        passed=report.valid && !isempty(bindings) && plant.plant_total === 4.0f0,
        evidence=:executable_model,
    )
end

function _contract_adapter_oracle()
    scenario = AdapterModelExample.adapter_scenario(Float32)
    report = validate_scenario(scenario; strict=true)
    simulation = run!(scenario; steps=1, outputs=:none)
    plant = final_state(simulation, One(scale=:Plant))
    return (
        passed=report.valid && plant.observed_par === 30.0f0,
        evidence=:executable_model,
    )
end

function _missing_environment_input_oracle()
    model_report = validate_model(
        MissingEnvironmentExample.MissingCO2Probe();
        strict=true,
    )
    scenario = MissingEnvironmentExample.missing_environment_scenario()
    message = try
        validate_environment_inputs(scenario)
        ""
    catch error
        sprint(showerror, error)
    end
    return (
        passed=model_report.valid &&
               occursin("missing_co2_probe", message) &&
               occursin("CO2", message),
        evidence=:executable_model,
        diagnostic=message,
    )
end

function _hard_call_publication_oracle()
    scenario = RuntimePatternsExample.hard_call_scenario(Float32)
    report = validate_scenario(scenario; strict=true)
    simulation = run!(scenario; steps=1, outputs=:all)
    controller = final_state(simulation, :scene)
    stream = outputs(simulation)[
        (:call_counter, ObjectId(:counter_object), :value)
    ]
    return (
        passed=report.valid &&
               controller.trial_value === 1.0f0 &&
               controller.accepted_value === 2.0f0 &&
               length(stream) == 1 &&
               only(stream)[2] === 2.0f0,
        evidence=:executable_model,
    )
end

function _dynamic_organ_initializer_oracle()
    scenario = LifecycleOutputExample.lifecycle_scenario()
    report = validate_scenario(scenario; strict=true)
    simulation = run!(scenario; steps=1, outputs=:none)
    scene = final_state(simulation, :scene)
    leaf = final_state(simulation, :new_leaf)
    return (
        passed=report.valid &&
               scene.created &&
               scene.initializer_runs_seen == 1 &&
               leaf.initializer_runs == 1,
        evidence=:executable_model,
    )
end

function _generic_numeric_types_oracle()
    float_status = MinimalModelExample.direct_example(Float32)
    rational_model = MinimalModelExample.RadiationUseEfficiency(3 // 2)
    rational_status = Status(
        intercepted_par=10 // 1,
        biomass_increment=0 // 1,
    )
    PlantSimEngine.run!(
        rational_model,
        rational_status,
        NamedTuple(),
        nothing,
        nothing,
    )
    return (
        passed=float_status.biomass_increment === 15.0f0 &&
               rational_status.biomass_increment == 15 // 1 &&
               rational_status.biomass_increment isa Rational{Int},
        evidence=:executable_model,
    )
end

function _two_process_package_layout_oracle()
    root = joinpath(ORACLE_FIXTURE_ROOT, "two-process-package")
    required = (
        "src/signal_supply/process.jl",
        "src/signal_supply/ConstantSignal.jl",
        "src/signal_response/process.jl",
        "src/signal_response/LinearResponse.jl",
        "test/runtests.jl",
        "docs/src/models/signal-supply.md",
        "docs/src/models/signal-response.md",
    )
    layout_valid = all(path -> isfile(joinpath(root, path)), required)
    models_valid = validate_model(
        TwoProcessFixture.ConstantSignal(2.0f0);
        strict=true,
    ).valid && validate_model(
        TwoProcessFixture.LinearResponse(3.0f0);
        strict=true,
    ).valid
    scenario = TwoProcessFixture.fixture_scenario(Float32)
    scenario_valid = validate_scenario(scenario; strict=true).valid
    simulation = run!(scenario; steps=1, outputs=:none)
    return (
        passed=layout_valid &&
               models_valid &&
               scenario_valid &&
               final_state(simulation).response === 6.0f0,
        evidence=:executable_model,
    )
end

const ORACLE_RUNNERS = Dict{Symbol,Function}(
    :workspace_direct_trigger => _workspace_direct_trigger_oracle,
    :workspace_plantsimengine_dependency =>
        _workspace_plantsimengine_dependency_oracle,
    :workspace_incomplete_request => _workspace_incomplete_request_oracle,
    :workspace_generic_julia => _workspace_generic_julia_oracle,
    :workspace_stale_environment => _workspace_stale_environment_oracle,
    :existing_process_model => _existing_process_model_oracle,
    :drop_in_alternative => _drop_in_alternative_oracle,
    :same_process_binding_changes => _same_process_binding_changes_oracle,
    :many_subtree_coupling => _many_subtree_coupling_oracle,
    :contract_adapter => _contract_adapter_oracle,
    :missing_environment_input => _missing_environment_input_oracle,
    :hard_call_publication => _hard_call_publication_oracle,
    :dynamic_organ_initializer => _dynamic_organ_initializer_oracle,
    :generic_numeric_types => _generic_numeric_types_oracle,
    :two_process_package_layout => _two_process_package_layout_oracle,
)

function run_oracle(case_id::Symbol)
    case = evaluation_case(case_id)
    runner = get(ORACLE_RUNNERS, case.oracle, nothing)
    isnothing(runner) && error("No oracle runner registered for $(case.oracle).")
    result = runner()
    result.passed || error("Evaluation oracle $(case_id) failed: $(result)")
    return result
end
