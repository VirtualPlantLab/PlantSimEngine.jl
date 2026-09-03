using Dates
using JSON
using PlantSimEngine
using PlantSimEngine.Authoring
using Test

abstract type AbstractAuthoringLinearModel <: PlantSimEngine.AbstractModel end
abstract type AbstractAuthoringOtherModel <: PlantSimEngine.AbstractModel end
abstract type AbstractAuthoringInvalidModel <: PlantSimEngine.AbstractModel end

PlantSimEngine.process_(::Type{AbstractAuthoringLinearModel}) = :authoring_linear
PlantSimEngine.process_(::Type{AbstractAuthoringOtherModel}) = :authoring_other
PlantSimEngine.process_(::Type{AbstractAuthoringInvalidModel}) = :authoring_invalid

struct AuthoringLinearModel{T} <: AbstractAuthoringLinearModel
    gain::T
    offset::T
end

struct AuthoringAlternativeModel{T} <: AbstractAuthoringLinearModel
    gain::T
    offset::T
end

struct AuthoringDifferentCadenceModel{T} <: AbstractAuthoringLinearModel
    gain::T
    offset::T
end

struct AuthoringDifferentDependencyModel{T} <: AbstractAuthoringLinearModel
    gain::T
    offset::T
end

struct AuthoringDifferentOutputPolicyModel{T} <: AbstractAuthoringLinearModel
    gain::T
    offset::T
end

struct AuthoringNarrowInputModel{T} <: AbstractAuthoringLinearModel
    gain::T
    offset::T
end

struct AuthoringRenamedOutputModel{T} <: AbstractAuthoringLinearModel
    gain::T
end

struct AuthoringOtherProcessModel <: AbstractAuthoringOtherModel end
struct AuthoringContractlessModel <: AbstractAuthoringLinearModel end
struct AuthoringIncompleteContractModel <: AbstractAuthoringLinearModel end
struct AuthoringInvalidMetadataModel <: AbstractAuthoringLinearModel end
struct AuthoringInvalidParameterMetadataModel <: AbstractAuthoringLinearModel
    gain::Float64
end
struct AuthoringInvalidInputModel <: AbstractAuthoringInvalidModel end

const AUTHORING_CONSTRUCTOR_CALLS = Ref(0)

struct AuthoringConstructorCountModel <: AbstractAuthoringOtherModel
    gain::Float64

    function AuthoringConstructorCountModel(gain::Float64)
        AUTHORING_CONSTRUCTOR_CALLS[] += 1
        return new(gain)
    end
end

const AUTHORING_DIMENSIONLESS = VariableContract(
    unit=:dimensionless,
    basis=:object,
    temporal=:step,
    aggregation=:instantaneous,
    extent=:intensive,
)
const AUTHORING_TEMPERATURE = VariableContract(
    unit=:degree_celsius,
    basis=:environment,
    temporal=:step,
    aggregation=:instantaneous,
    extent=:intensive,
)

const AUTHORING_DROP_IN_MODELS = Union{
    AuthoringLinearModel,
    AuthoringAlternativeModel,
    AuthoringDifferentCadenceModel,
    AuthoringDifferentDependencyModel,
    AuthoringDifferentOutputPolicyModel,
}

PlantSimEngine.inputs_(::AUTHORING_DROP_IN_MODELS) =
    (x=Required(Real),)
PlantSimEngine.outputs_(model::AUTHORING_DROP_IN_MODELS) =
    (y=zero(model.gain),)
PlantSimEngine.environment_inputs_(
    model::AUTHORING_DROP_IN_MODELS,
) = (T=zero(model.gain),)
PlantSimEngine.variable_contracts_(
    ::AUTHORING_DROP_IN_MODELS,
) = (
    x=AUTHORING_DIMENSIONLESS,
    y=AUTHORING_DIMENSIONLESS,
    T=AUTHORING_TEMPERATURE,
)

PlantSimEngine.inputs_(::AuthoringNarrowInputModel) = (x=Required(Float64),)
PlantSimEngine.outputs_(model::AuthoringNarrowInputModel) = (y=zero(model.gain),)
PlantSimEngine.environment_inputs_(model::AuthoringNarrowInputModel) =
    (T=zero(model.gain),)
PlantSimEngine.variable_contracts_(::AuthoringNarrowInputModel) = (
    x=AUTHORING_DIMENSIONLESS,
    y=AUTHORING_DIMENSIONLESS,
    T=AUTHORING_TEMPERATURE,
)

PlantSimEngine.inputs_(::AuthoringRenamedOutputModel) = (x=Required(Real),)
PlantSimEngine.outputs_(model::AuthoringRenamedOutputModel) = (z=zero(model.gain),)
PlantSimEngine.environment_inputs_(model::AuthoringRenamedOutputModel) =
    (T=zero(model.gain),)
PlantSimEngine.variable_contracts_(::AuthoringRenamedOutputModel) = (
    x=AUTHORING_DIMENSIONLESS,
    z=AUTHORING_DIMENSIONLESS,
    T=AUTHORING_TEMPERATURE,
)

PlantSimEngine.inputs_(::AuthoringOtherProcessModel) = (x=Required(Real),)
PlantSimEngine.outputs_(::AuthoringOtherProcessModel) = (y=0.0,)
PlantSimEngine.environment_inputs_(::AuthoringOtherProcessModel) = (T=0.0,)
PlantSimEngine.variable_contracts_(::AuthoringOtherProcessModel) = (
    x=AUTHORING_DIMENSIONLESS,
    y=AUTHORING_DIMENSIONLESS,
    T=AUTHORING_TEMPERATURE,
)

PlantSimEngine.inputs_(::AuthoringContractlessModel) = (x=Required(Real),)
PlantSimEngine.outputs_(::AuthoringContractlessModel) = (y=0.0,)
PlantSimEngine.inputs_(::AuthoringIncompleteContractModel) = (x=Required(Real),)
PlantSimEngine.outputs_(::AuthoringIncompleteContractModel) = (y=0.0,)
PlantSimEngine.variable_contracts_(::AuthoringIncompleteContractModel) = (
    x=VariableContract(unit=:dimensionless),
    y=AUTHORING_DIMENSIONLESS,
)
PlantSimEngine.inputs_(::AuthoringInvalidMetadataModel) = (x=Required(Real),)
PlantSimEngine.outputs_(::AuthoringInvalidMetadataModel) = (y=0.0,)
PlantSimEngine.environment_inputs_(::AuthoringInvalidMetadataModel) = (T=0.0,)
PlantSimEngine.variable_contracts_(::AuthoringInvalidMetadataModel) = (
    x=AUTHORING_DIMENSIONLESS,
    y=AUTHORING_DIMENSIONLESS,
    T=AUTHORING_TEMPERATURE,
)
PlantSimEngine.inputs_(::AuthoringInvalidParameterMetadataModel) = (x=Required(Real),)
PlantSimEngine.outputs_(::AuthoringInvalidParameterMetadataModel) = (y=0.0,)
PlantSimEngine.inputs_(::AuthoringInvalidInputModel) = (x=0.0,)
PlantSimEngine.outputs_(::AuthoringInvalidInputModel) = (y=0.0,)
PlantSimEngine.inputs_(::AuthoringConstructorCountModel) = NamedTuple()
PlantSimEngine.outputs_(model::AuthoringConstructorCountModel) = (y=model.gain,)

PlantSimEngine.timespec(::Type{<:AuthoringDifferentCadenceModel}) = ClockSpec(2.0, 0.0)
PlantSimEngine.dep(::AuthoringDifferentDependencyModel) = (x=Input(One(within=Self())),)
PlantSimEngine.output_policy(::Type{<:AuthoringDifferentOutputPolicyModel}) =
    (y=Integrate(),)
PlantSimEngine.Authoring.model_metadata(::AuthoringLinearModel) = (
    summary="A linear authoring API fixture.",
    maturity=:validated_fixture,
)
PlantSimEngine.Authoring.model_metadata(::AuthoringInvalidMetadataModel) = "not structured"
PlantSimEngine.Authoring.parameter_metadata(::AuthoringLinearModel) = (
    gain=(
        description="Multiplicative gain.",
        unit=:dimensionless,
        domain=(minimum=0.0,),
        reference="Authoring test fixture",
    ),
)
PlantSimEngine.Authoring.parameter_metadata(::AuthoringInvalidParameterMetadataModel) = (
    unknown=(description="Not a model field.",),
)

function PlantSimEngine.run!(
    model::Union{
        AuthoringLinearModel,
        AuthoringAlternativeModel,
        AuthoringDifferentCadenceModel,
        AuthoringDifferentDependencyModel,
        AuthoringDifferentOutputPolicyModel,
        AuthoringNarrowInputModel,
    },
    status,
    environment,
    constants,
    context,
)
    status.y = model.gain * status.x + model.offset
    return nothing
end

function PlantSimEngine.run!(
    model::AuthoringRenamedOutputModel,
    status,
    environment,
    constants,
    context,
)
    status.z = model.gain * status.x
    return nothing
end


function PlantSimEngine.run!(
    ::AuthoringInvalidParameterMetadataModel,
    status,
    environment,
    constants,
    context,
)
    status.y = status.x
    return nothing
end

function PlantSimEngine.run!(
    ::AuthoringOtherProcessModel,
    status,
    environment,
    constants,
    context,
)
    status.y = status.x
    return nothing
end

function PlantSimEngine.run!(
    ::Union{
        AuthoringContractlessModel,
        AuthoringIncompleteContractModel,
        AuthoringInvalidMetadataModel,
    },
    status,
    environment,
    constants,
    context,
)
    status.y = status.x
    return nothing
end

@testset "exact model descriptions" begin
    model = AuthoringLinearModel(2.0f0, 0.5f0)
    description = describe_model(model)

    @test description isa ModelDescription
    @test description.schema_version == SCHEMA_VERSION
    @test description.provenance == :exact
    @test description.process == :authoring_linear
    @test description.field_provenance.parameters.values == :exact
    @test description.field_provenance.parameters.metadata == :declared
    @test description.field_provenance.interface.instance == :exact
    @test description.field_provenance.ports.contracts == :declared
    @test description.field_provenance.source == :inferred
    @test description.field_provenance.constructor.defaults == :unavailable
    @test description.complete
    @test description.interface == model_interface(model)
    @test description.interface.provenance == :exact
    @test description.interface.process == :authoring_linear
    @test description.interface.inputs.x isa Required{Real}
    @test description.interface.outputs.y == 0.0f0
    @test description.source_file == @__FILE__
    @test description.source_line isa Int
    @test description.metadata.maturity == :validated_fixture
    @test [(parameter.name, parameter.value_type, parameter.value) for
           parameter in description.parameters] == [
        (:gain, "Float32", 2.0f0),
        (:offset, "Float32", 0.5f0),
    ]
    @test description.parameters[1].metadata.description == "Multiplicative gain."
    @test description.parameters[1].metadata.domain.minimum == 0.0
    @test isempty(description.parameters[2].metadata)

    x_port = only(port for port in description.ports if port.name == :x)
    @test x_port.role == :input
    @test x_port.declaration == :required
    @test x_port.expected_type == "Real"
    @test x_port.variable_contract == AUTHORING_DIMENSIONLESS

    payload = to_dict(description)
    @test payload["schemaVersion"] == SCHEMA_VERSION
    @test payload["provenance"] == "exact"
    @test payload["process"] == "authoring_linear"
    @test payload["fieldProvenance"]["module"] == "declared"
    @test payload["fieldProvenance"]["parameters"]["values"] == "exact"
    @test payload["fieldProvenance"]["parameters"]["metadata"] == "declared"
    @test payload["fieldProvenance"]["constructor"]["defaults"] == "unavailable"
    @test payload["parameters"][1]["value"] == 2.0f0
    @test payload["parameters"][1]["metadata"]["unit"] == "dimensionless"
    @test payload["interface"]["inputs"]["x"]["expectedType"] == "Real"
    @test JSON.parse(to_json(description))["kind"] == "modelDescription"

    type_description = describe_model(AuthoringLinearModel)
    @test type_description.provenance == :best_effort
    @test type_description.process == :authoring_linear
    @test type_description.field_provenance.parameters == :unavailable
    @test type_description.field_provenance.interface == :unavailable
    @test !type_description.complete
    @test isempty(type_description.parameters)
    @test isnothing(type_description.interface)
    @test only(type_description.diagnostics).code == :model_instance_required
    @test_throws ArgumentError model_interface(AuthoringLinearModel)

    zero_arg_interface = model_interface(AuthoringOtherProcessModel)
    @test zero_arg_interface.provenance == :best_effort
    @test zero_arg_interface.process == :authoring_other
    zero_arg_description = describe_model(AuthoringOtherProcessModel)
    @test zero_arg_description.interface.provenance == :best_effort
    @test zero_arg_description.constructor["hasZeroArgConstructor"]
    @test zero_arg_description.constructor["hasInspectedDefaults"]
    @test zero_arg_description.field_provenance.parameters.values == :best_effort
    @test zero_arg_description.field_provenance.interface.instance == :best_effort

    counted_model = AuthoringConstructorCountModel(3.0)
    AUTHORING_CONSTRUCTOR_CALLS[] = 0
    counted_description = describe_model(counted_model)
    @test AUTHORING_CONSTRUCTOR_CALLS[] == 0
    @test only(counted_description.parameters).value == 3.0
    @test !only(counted_description.constructor["fields"])["hasDefault"]
    @test isnothing(only(counted_description.constructor["fields"])["default"])
    @test !counted_description.constructor["hasZeroArgConstructor"]
    @test !counted_description.constructor["hasInspectedDefaults"]

    invalid_type_description = describe_model(AuthoringInvalidInputModel)
    @test !invalid_type_description.complete
    @test isnothing(invalid_type_description.interface)
    @test invalid_type_description.process == :authoring_invalid
    @test only(invalid_type_description.diagnostics).code == :model_description_failed
end

@testset "model interfaces are the runtime override authority" begin
    base = AuthoringLinearModel(2.0, 0.5)
    alternative = AuthoringAlternativeModel(3.0, 1.0)
    different_cadence = AuthoringDifferentCadenceModel(3.0, 1.0)
    different_dependency = AuthoringDifferentDependencyModel(3.0, 1.0)
    different_output_policy = AuthoringDifferentOutputPolicyModel(3.0, 1.0)
    narrow_input = AuthoringNarrowInputModel(3.0, 1.0)
    renamed = AuthoringRenamedOutputModel(2.0)
    other = AuthoringOtherProcessModel()

    direct = compare_models(base, alternative)
    @test direct.same_process
    @test direct.override_compatible
    @test !direct.requires_binding_changes
    @test !direct.requires_reconfiguration
    @test direct.compatibility == :direct_override
    @test isempty(direct.differences)

    cadence = compare_models(base, different_cadence)
    @test cadence.same_process
    @test !cadence.override_compatible
    @test !cadence.requires_binding_changes
    @test cadence.requires_reconfiguration
    @test cadence.compatibility == :same_process_requires_reconfiguration
    @test any(
        difference -> difference.path == "traits.timespec" &&
                      difference.affects_override &&
                      !difference.affects_bindings,
        cadence.differences,
    )

    dependency = compare_models(base, different_dependency)
    @test !dependency.override_compatible
    @test dependency.requires_binding_changes
    @test any(
        difference -> difference.path == "dependencies.x" &&
                      difference.kind == :added &&
                      difference.affects_bindings,
        dependency.differences,
    )

    policy = compare_models(base, different_output_policy)
    @test !policy.override_compatible
    @test policy.requires_binding_changes
    @test any(
        difference -> difference.path == "traits.output_policy" &&
                      difference.affects_override &&
                      difference.affects_bindings,
        policy.differences,
    )

    schema_change = compare_models(base, narrow_input)
    @test !schema_change.override_compatible
    @test schema_change.requires_binding_changes
    @test any(
        difference -> difference.path == "inputs.x" &&
                      difference.kind == :changed &&
                      difference.affects_override &&
                      difference.affects_bindings,
        schema_change.differences,
    )

    rebinding = compare_models(base, renamed)
    @test rebinding.same_process
    @test !rebinding.override_compatible
    @test rebinding.requires_binding_changes
    @test rebinding.requires_reconfiguration
    @test rebinding.compatibility == :same_process_requires_reconfiguration
    @test any(
        difference -> difference.path == "outputs.y" &&
                      difference.kind == :removed &&
                      difference.affects_override,
        rebinding.differences,
    )
    @test any(
        difference -> difference.path == "outputs.z" &&
                      difference.kind == :added,
        rebinding.differences,
    )

    different_process = compare_models(base, other)
    @test !different_process.same_process
    @test different_process.compatibility == :different_process
    serialized_rebinding = JSON.parse(to_json(rebinding))
    @test serialized_rebinding["requiresBindingChanges"]
    @test serialized_rebinding["requiresReconfiguration"]

    template = CompositeModelTemplate(
        (
            ModelSpec(base; name=:linear, on=One(scale=:Leaf)),
        ),
    )
    compatible_instance = ObjectInstance(
        :plant_a,
        template;
        root=Object(:plant_a; scale=:Plant),
        objects=(
            Object(
                :leaf_a;
                scale=:Leaf,
                parent=:plant_a,
                status=Status(x=1.0),
            ),
        ),
        overrides=(linear=alternative,),
    )
    @test CompositeModel(compatible_instance) isa CompositeModel

    incompatible_instance = ObjectInstance(
        :plant_b,
        template;
        root=Object(:plant_b; scale=:Plant),
        objects=(
            Object(
                :leaf_b;
                scale=:Leaf,
                parent=:plant_b,
                status=Status(x=1.0),
            ),
        ),
        overrides=(linear=renamed,),
    )
    @test_throws "incompatible model contract" CompositeModel(incompatible_instance)

    cadence_instance = ObjectInstance(
        :plant_c,
        template;
        root=Object(:plant_c; scale=:Plant),
        objects=(
            Object(
                :leaf_c;
                scale=:Leaf,
                parent=:plant_c,
                status=Status(x=1.0),
            ),
        ),
        overrides=(linear=different_cadence,),
    )
    @test_throws "incompatible model contract" CompositeModel(cadence_instance)
end

@testset "model validation is structured and optionally contract-strict" begin
    model = AuthoringLinearModel(2.0, 0.5)
    report = validate_model(model; strict=true)
    @test report isa ModelValidationReport
    @test report.valid
    @test isempty(report.diagnostics)
    @test JSON.parse(to_json(report))["valid"]

    contractless = validate_model(AuthoringContractlessModel())
    @test contractless.valid
    strict_contractless = validate_model(AuthoringContractlessModel(); strict=true)
    @test !strict_contractless.valid
    @test any(
        diagnostic -> diagnostic.code == :missing_variable_contract,
        strict_contractless.diagnostics,
    )

    incomplete = validate_model(AuthoringIncompleteContractModel(); strict=true)
    @test !incomplete.valid
    incomplete_diagnostic = only(
        diagnostic for diagnostic in incomplete.diagnostics
        if diagnostic.code == :incomplete_variable_contract
    )
    @test incomplete_diagnostic.context["variable"] == "x"
    @test Set(incomplete_diagnostic.context["missingFields"]) ==
          Set(["basis", "temporal", "aggregation", "extent"])

    invalid = validate_model(AuthoringInvalidInputModel())
    @test !invalid.valid
    @test any(diagnostic -> diagnostic.code == :invalid_inputs, invalid.diagnostics)
    @test any(diagnostic -> diagnostic.code == :missing_run_method, invalid.diagnostics)

    invalid_parameters = validate_model(AuthoringInvalidParameterMetadataModel(1.0))
    @test !invalid_parameters.valid
    @test any(
        diagnostic -> diagnostic.code == :invalid_parameter_metadata,
        invalid_parameters.diagnostics,
    )
end

@testset "scenario validation preserves partial compiler evidence" begin
    model = AuthoringLinearModel(2.0, 0.5)
    valid_scenario = CompositeModel(
        Object(:leaf; scale=:Leaf, status=Status(x=1.0));
        applications=(
            ModelSpec(model; name=:linear, on=One(scale=:Leaf)),
        ),
        environment=(T=25.0, duration=3600.0),
    )
    valid_report = validate_scenario(valid_scenario; strict=true)
    @test valid_report isa ScenarioValidationReport
    @test valid_report.valid
    @test valid_report.summary.compiled
    @test valid_report.summary.application_count == 1
    @test !isnothing(valid_report.compilation.compiled)
    @test JSON.parse(to_json(valid_report))["summary"]["compiled"]

    unresolved_scenario = CompositeModel(
        Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(model; name=:linear, on=One(scale=:Leaf)),
        ),
        environment=(T=25.0, duration=3600.0),
    )
    unresolved_report = validate_scenario(unresolved_scenario)
    @test !unresolved_report.valid
    @test unresolved_report.summary.compiled
    @test any(
        diagnostic -> diagnostic.code == :unresolved_required_input &&
                      diagnostic.context["variable"] == "x",
        unresolved_report.diagnostics,
    )

    invalid_selector = CompositeModel(
        Object(:leaf; scale=:Leaf, status=Status(x=1.0));
        applications=(
            ModelSpec(model; name=:linear, on=One(scale=:Missing)),
        ),
        environment=(T=25.0, duration=3600.0),
    )
    partial_report = validate_scenario(invalid_selector)
    @test !partial_report.valid
    @test isnothing(partial_report.compilation.compiled)
    @test !isempty(partial_report.diagnostics)
    @test JSON.parse(to_json(partial_report))["schemaVersion"] == SCHEMA_VERSION

    override_template = CompositeModelTemplate((
        ModelSpec(model; name=:linear, on=Many(scale=:Leaf)),
    ))
    overridden_instance = ObjectInstance(
        :overridden,
        override_template;
        root=Object(:overridden_plant; scale=:Plant),
        objects=(
            Object(
                :ordinary_leaf;
                scale=:Leaf,
                parent=:overridden_plant,
                status=Status(x=1.0),
            ),
            Object(
                :invalid_leaf;
                scale=:Leaf,
                parent=:overridden_plant,
                status=Status(x=1.0),
            ),
        ),
        object_overrides=(
            Override(
                object=:invalid_leaf,
                application=:linear,
                model=AuthoringInvalidMetadataModel(),
            ),
        ),
    )
    overridden_scenario = CompositeModel(
        overridden_instance;
        environment=(T=25.0, duration=3600.0),
    )
    overridden_report = validate_scenario(overridden_scenario)
    @test !overridden_report.valid
    @test any(
        diagnostic -> diagnostic.code == :invalid_model_metadata &&
                      diagnostic.context["modelType"] ==
                      "AuthoringInvalidMetadataModel",
        overridden_report.diagnostics,
    )
end
