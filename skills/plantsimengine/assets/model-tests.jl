module ModelAuthoringExamplesTests

using Test
using PlantSimEngine
using PlantSimEngine.Authoring

include(joinpath(@__DIR__, "minimal-model.jl"))
include(joinpath(@__DIR__, "alternative-model.jl"))
include(joinpath(@__DIR__, "adapter-model.jl"))
include(joinpath(@__DIR__, "coupling-patterns.jl"))
include(joinpath(@__DIR__, "runtime-patterns.jl"))
include(joinpath(@__DIR__, "lifecycle-output.jl"))

using .AdapterModelExample
using .AlternativeModelExample
using .CouplingPatternsExample
using .LifecycleOutputExample
using .MinimalModelExample
using .RuntimePatternsExample

@testset "minimal model authoring example" begin
    model = RadiationUseEfficiency(1.5f0)

    @test process(model) == :biomass_production
    @test propertynames(PlantSimEngine.inputs_(model)) == (:intercepted_par,)
    @test propertynames(PlantSimEngine.outputs_(model)) == (:biomass_increment,)
    @test variable_contracts(model) == (
        intercepted_par=MinimalModelExample.INTERCEPTED_PAR_CONTRACT,
        biomass_increment=MinimalModelExample.BIOMASS_INCREMENT_CONTRACT,
    )
    @test model_metadata(model).maturity == :pedagogical_non_calibrated
    @test isnothing(model_metadata(model).reference)
    @test haskey(parameter_metadata(model), :rue)
    description = describe_model(model)
    @test description.metadata.maturity == :pedagogical_non_calibrated
    @test only(description.parameters).metadata.unit ==
          :g_dry_matter_per_mol_photon
    @test validate_model(model; strict=true).valid

    direct_status = direct_example(Float32)
    @test direct_status.biomass_increment == 15.0f0
    @test direct_status.biomass_increment isa Float32

    scenario = single_object_scenario(Float32)
    Diagnostics.explain_initialization(scenario)
    simulation = run!(scenario; steps=1, outputs=:none)
    result = final_state(simulation)
    @test result.biomass_increment == 15.0f0
    @test result.biomass_increment isa Float32
end

@testset "same process is distinct from substitutability" begin
    linear = LinearCarbonGain(1.25f0)
    saturating = SaturatingCarbonGain(10.0f0, 5.0f0)
    water_limited = WaterLimitedCarbonGain(1.25f0)

    @test process(linear) == process(saturating) == process(water_limited) ==
          :carbon_gain

    linear_inputs = propertynames(PlantSimEngine.inputs_(linear))
    saturating_inputs = propertynames(PlantSimEngine.inputs_(saturating))
    water_limited_inputs = propertynames(PlantSimEngine.inputs_(water_limited))

    @test linear_inputs == saturating_inputs == (:absorbed_par,)
    @test water_limited_inputs == (:absorbed_par, :ftsw)
    @test variable_contracts(linear) == variable_contracts(saturating)
    @test variable_contracts(linear) != variable_contracts(water_limited)
    @test all(
        model_metadata(model).maturity == :pedagogical_non_calibrated
        for model in (linear, saturating, water_limited)
    )
    @test all(
        isnothing(model_metadata(model).reference)
        for model in (linear, saturating, water_limited)
    )
    @test all(
        isempty(propertynames(PlantSimEngine.environment_inputs_(model))) &&
        isempty(propertynames(PlantSimEngine.environment_outputs_(model)))
        for model in (linear, saturating, water_limited)
    )
    @test all(
        validate_model(model; strict=true).valid
        for model in (linear, saturating, water_limited)
    )
    @test propertynames(parameter_metadata(saturating)) ==
          (:maximum, :half_saturation)

    direct_comparison = compare_models(linear, saturating)
    @test direct_comparison.same_process
    @test direct_comparison.override_compatible
    @test !direct_comparison.requires_binding_changes
    @test direct_comparison.compatibility == :direct_override

    rebinding_comparison = compare_models(linear, water_limited)
    @test rebinding_comparison.same_process
    @test !rebinding_comparison.override_compatible
    @test rebinding_comparison.requires_binding_changes
    @test rebinding_comparison.requires_reconfiguration
    @test rebinding_comparison.compatibility ==
          :same_process_requires_reconfiguration
    @test any(difference -> difference.affects_override, rebinding_comparison.differences)

    linear_status = Status(absorbed_par=4.0f0, carbon_gain=0.0f0)
    PlantSimEngine.run!(linear, linear_status, NamedTuple(), nothing, nothing)
    @test linear_status.carbon_gain == 5.0f0
    @test linear_status.carbon_gain isa Float32

    saturating_status = Status(absorbed_par=5.0f0, carbon_gain=0.0f0)
    PlantSimEngine.run!(
        saturating,
        saturating_status,
        NamedTuple(),
        nothing,
        nothing,
    )
    @test saturating_status.carbon_gain == 5.0f0

    water_status = Status(
        absorbed_par=4.0f0,
        ftsw=0.5f0,
        carbon_gain=0.0f0,
    )
    PlantSimEngine.run!(
        water_limited,
        water_status,
        NamedTuple(),
        nothing,
        nothing,
    )
    @test water_status.carbon_gain == 2.5f0
end

@testset "explicit scientific adapter" begin
    @test all(
        isempty(propertynames(PlantSimEngine.environment_inputs_(model))) &&
        isempty(propertynames(PlantSimEngine.environment_outputs_(model)))
        for model in (
            GroundRadiation(12.0f0),
            GroundToPlantRadiation(2.5f0),
            ObservePlantRadiation(),
        )
    )
    scenario = adapter_scenario(Float32)
    Diagnostics.explain_initialization(scenario)
    Diagnostics.explain_bindings(scenario)
    @test validate_scenario(scenario; strict=true).valid

    simulation = run!(scenario; steps=1, outputs=:none)
    plant_status = final_state(simulation, One(scale=:Plant))

    @test plant_status.par_ground == 12.0f0
    @test plant_status.par_plant == 30.0f0
    @test plant_status.observed_par == 30.0f0
    @test plant_status.observed_par isa Float32
end

@testset "One, OptionalOne, renamed, and Many Subtree coupling" begin
    source = ConstantLeafSignal(2.0f0)
    one_observer = ObserveOneSignal()
    optional_observer = ObserveOptionalSignal()
    total = SumLeafSignals()

    @test all(
        validate_model(model; strict=true).valid
        for model in (source, one_observer, optional_observer, total)
    )

    source_status = Status(leaf_signal=0.0f0)
    PlantSimEngine.run!(source, source_status, NamedTuple(), nothing, nothing)
    @test source_status.leaf_signal === 2.0f0

    one_status = Status(selected_signal=3.0f0, one_seen=0.0f0)
    PlantSimEngine.run!(
        one_observer,
        one_status,
        NamedTuple(),
        nothing,
        nothing,
    )
    @test one_status.one_seen === 3.0f0

    optional_status = Status(optional_signal=0.0f0, optional_seen=1.0f0)
    PlantSimEngine.run!(
        optional_observer,
        optional_status,
        NamedTuple(),
        nothing,
        nothing,
    )
    @test optional_status.optional_seen === 0.0f0

    total_status = Status(leaf_signals=Float32[1, 2], plant_total=0.0f0)
    PlantSimEngine.run!(total, total_status, NamedTuple(), nothing, nothing)
    @test total_status.plant_total === 3.0f0

    scenario = coupling_scenario(Float32)
    @test validate_scenario(scenario; strict=true).valid
    @test !isempty(Diagnostics.explain_applications(scenario))
    @test !isempty(Diagnostics.explain_bindings(scenario))
    Diagnostics.explain_writers(scenario)
    Diagnostics.explain_schedule(scenario)
    Diagnostics.explain_execution_plan(scenario)

    simulation = run!(scenario; steps=1, outputs=:none)
    plant = final_state(simulation, One(scale=:Plant))
    @test plant.one_seen === 2.0f0
    @test plant.optional_seen === 0.0f0
    @test plant.plant_total === 4.0f0
end

@testset "temporal policies and PreviousTimeStep" begin
    hourly = HourlySignal(1.0f0)
    hourly_status = Status(signal=0.0f0)
    PlantSimEngine.run!(hourly, hourly_status, NamedTuple(), nothing, nothing)
    @test hourly_status.signal === 1.0f0

    lagged = LaggedIncrement(1.0f0)
    lagged_status = Status(previous_state=5.0f0, state=0.0f0)
    PlantSimEngine.run!(lagged, lagged_status, NamedTuple(), nothing, nothing)
    @test lagged_status.state === 6.0f0

    scenario = temporal_scenario(Float32)
    @test validate_scenario(scenario; strict=true).valid
    @test !isempty(Diagnostics.explain_bindings(scenario))
    Diagnostics.explain_schedule(scenario)

    simulation = run!(scenario; steps=3, outputs=:none)
    state = final_state(simulation)
    @test state.signal === 3.0f0
    @test state.observed_signal === 3.0f0
    @test state.state === 8.0f0
end

@testset "hard-call accepted publication" begin
    scenario = hard_call_scenario(Float32)
    @test validate_scenario(scenario; strict=true).valid
    @test !isempty(Diagnostics.explain_calls(scenario))
    Diagnostics.explain_schedule(scenario)

    simulation = run!(scenario; steps=1, outputs=:all)
    controller = final_state(simulation, :scene)
    counter = final_state(simulation, :counter_object)
    @test controller.trial_value === 1.0f0
    @test controller.accepted_value === 2.0f0
    @test counter.value === 2.0f0
    @test counter.calls == 2

    accepted_stream = outputs(simulation)[
        (:call_counter, ObjectId(:counter_object), :value)
    ]
    @test length(accepted_stream) == 1
    @test only(accepted_stream)[2] === 2.0f0
end

@testset "lifecycle initializer through register_object!" begin
    scenario = lifecycle_scenario()
    @test validate_scenario(scenario; strict=true).valid
    Diagnostics.explain_applications(scenario)
    @test !isempty(Diagnostics.explain_calls(scenario))

    simulation = run!(scenario; steps=1, outputs=:none)
    scene = final_state(simulation, :scene)
    leaf = final_state(simulation, :new_leaf)
    @test scene.created
    @test scene.initializer_runs_seen == 1
    @test leaf.initializer_runs == 1
end

@testset "identity-aware outputs_to" begin
    scenario = distributed_output_scenario(Float32)
    @test validate_scenario(scenario; strict=true).valid
    Diagnostics.explain_applications(scenario)
    Diagnostics.explain_writers(scenario)

    simulation = run!(scenario; steps=1, outputs=:none)
    @test final_state(simulation, :scene).assigned_count == 2
    @test final_state(simulation, :leaf_1).incident_signal === 12.0f0
    @test final_state(simulation, :leaf_2).incident_signal === 11.0f0
end

end # module ModelAuthoringExamplesTests
