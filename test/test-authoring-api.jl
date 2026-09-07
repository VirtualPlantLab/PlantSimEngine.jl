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
struct AuthoringShortKernelModel <: AbstractAuthoringInvalidModel end
struct AuthoringLongKernelModel <: AbstractAuthoringInvalidModel end
struct AuthoringVariadicKernelModel <: AbstractAuthoringLinearModel end
struct AuthoringFixedVariadicKernelModel <: AbstractAuthoringLinearModel end
struct AuthoringPolicyOrderModel{P} <: AbstractAuthoringLinearModel
    policies::P
end

struct AuthoringDistributedModel{D} <: AbstractAuthoringLinearModel
    declarations::D
end
PlantSimEngine.outputs_(model::AuthoringDistributedModel) = model.declarations
PlantSimEngine.run!(::AuthoringDistributedModel, status, environment, constants, context) = nothing
PlantSimEngine.variable_contracts_(::AuthoringDistributedModel) = (
    total=AUTHORING_DIMENSIONLESS,
    received=AUTHORING_DIMENSIONLESS,
    existing=AUTHORING_DIMENSIONLESS,
)

struct AuthoringDistributedContractModel{M} <: AbstractAuthoringLinearModel
    model::M
end
PlantSimEngine.outputs_(model::AuthoringDistributedContractModel) = PlantSimEngine.outputs_(model.model)
PlantSimEngine.variable_contracts_(model::AuthoringDistributedContractModel) =
    merge(PlantSimEngine.variable_contracts_(model.model), (received=AUTHORING_TEMPERATURE,))

struct AuthoringUnboundContractModel <: AbstractAuthoringLinearModel end
PlantSimEngine.variable_contracts_(::AuthoringUnboundContractModel) = (unbound=AUTHORING_DIMENSIONLESS,)
PlantSimEngine.run!(::AuthoringUnboundContractModel, status, environment, constants, context) = nothing

PlantSimEngine.run!(::AuthoringShortKernelModel, status, environment, constants) = nothing
PlantSimEngine.run!(::AuthoringLongKernelModel, status, environment, constants, context, extra) = nothing
PlantSimEngine.run!(::AuthoringVariadicKernelModel, status, arguments...) = nothing
PlantSimEngine.run!(::AuthoringFixedVariadicKernelModel, arguments::Vararg{Any,4}) = nothing
PlantSimEngine.outputs_(::AuthoringPolicyOrderModel) = (x=0.0, y=0.0)
PlantSimEngine.output_policy(model::AuthoringPolicyOrderModel) = model.policies
PlantSimEngine.run!(::AuthoringPolicyOrderModel, status, environment, constants, context) = nothing

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

@testset "Distributed model outputs are inspectable without a scenario" begin
    declarations = (
        total=Float32[0, 1],
        received=Distributed(Default(0.0f0)),
        existing=Distributed(Required(Real)),
    )
    model = AuthoringDistributedModel(declarations)
    description = describe_model(model)
    @test model_interface(model).outputs == declarations
    @test validate_model(model; strict=true).valid
    @test outputs(model) == (:total, :received, :existing)
    ports = Dict(port.name => port for port in description.ports)
    @test ports[:total].storage == :local
    @test ports[:total].expected_type == "Vector{Float32}"
    @test ports[:total].initial_value == Float32[0, 1]
    @test ports[:received].role == ports[:existing].role == :output
    @test ports[:received].storage == ports[:existing].storage == :distributed
    @test ports[:received].expected_type == "Float32"
    @test ports[:received].declaration == :defaulted
    @test ports[:received].initial_value === 0.0f0
    @test ports[:existing].expected_type == "Real"
    @test ports[:existing].declaration == :required
    @test isnothing(ports[:existing].initial_value)
    @test all(port.variable_contract == AUTHORING_DIMENSIONLESS for port in description.ports)

    serialized = JSON.parse(to_json(description))
    @test serialized["interface"]["outputs"]["received"]["kind"] == "distributed"
    @test serialized["interface"]["outputs"]["existing"]["declaration"]["expectedType"] == "Real"
    @test only(port for port in serialized["ports"] if port["name"] == "received")["storage"] == "distributed"

    compatible = compare_models(model, AuthoringDistributedModel(declarations))
    @test compatible.override_compatible
    local_output = compare_models(model, AuthoringDistributedModel(merge(declarations, (received=0.0f0,))))
    @test !local_output.override_compatible
    @test local_output.requires_binding_changes
    @test any(difference.path == "outputs.received" for difference in local_output.differences)
    changed_policy = compare_models(model, AuthoringDistributedModel(merge(declarations, (existing=Distributed(Default(0.0)),))))
    @test !changed_policy.override_compatible

    packet = (count=1, values=Float32[1, 2])
    packet_model = AuthoringDistributedModel(merge(declarations, (total=packet,)))
    packet_port = only(port for port in describe_model(packet_model).ports if port.name == :total)
    @test packet_port.storage == :local
    @test packet_port.expected_type == string(typeof(packet))
    @test packet_port.initial_value == packet

    array_declarations = merge(declarations, (received=Distributed(Default(Float32[1, 2])),))
    array_model = AuthoringDistributedModel(array_declarations)
    copied_array_model = AuthoringDistributedModel(deepcopy(array_declarations))
    array_comparison = compare_models(array_model, copied_array_model)
    @test array_comparison.override_compatible
    @test isempty(array_comparison.differences)
    @test hash(model_interface(array_model)) == hash(model_interface(copied_array_model))
    changed_array = AuthoringDistributedModel(merge(array_declarations, (received=Distributed(Default(Float32[1, 3])),)))
    @test compare_models(array_model, changed_array).override_compatible

    invalid = validate_model(AuthoringDistributedModel([:received => Distributed(Default(0.0))]))
    @test !invalid.valid
    @test any(diagnostic.code == :invalid_outputs for diagnostic in invalid.diagnostics)
    @test_throws "unknown variable" variable_contracts(AuthoringUnboundContractModel())
    @test !validate_model(AuthoringUnboundContractModel()).valid
end

@testset "Distributed default compatibility preserves kind, type, and contracts" begin
    declarations = (total=0.0f0, received=Distributed(Default(1.0f0)),
        existing=Distributed(Required(Real)))
    model = AuthoringDistributedModel(declarations)
    interface = model_interface(model)
    for (initial, replacement) in ((1.0f0, 9.0f0), (Float32[1, 2], Float32[9, 11]))
        left = AuthoringDistributedModel(merge(declarations, (received=Distributed(Default(initial)),)))
        right = AuthoringDistributedModel(merge(declarations, (received=Distributed(Default(replacement)),)))
        left_interface, right_interface = model_interface(left), model_interface(right)
        @test left_interface == right_interface
        @test isequal(left_interface, right_interface)
        @test hash(left_interface) == hash(right_interface)
        @test hash(left_interface, UInt(42)) == hash(right_interface, UInt(42))
        @test length(Set((left_interface, right_interface))) == 1
        @test right_interface.outputs.received.declaration.value == replacement
        comparison = compare_models(left, right)
        @test comparison.override_compatible
        @test !comparison.requires_binding_changes
        @test isempty(comparison.differences)
    end

    for changed in (
        (total=9.0f0,),
        (received=9.0f0,),
        (received=Distributed(Default(1.0)),),
        (received=Distributed(Required(Float32)),),
        (existing=Distributed(Required(Float32)),),
    )
        replacement = AuthoringDistributedModel(merge(declarations, changed))
        @test !isequal(interface, model_interface(replacement))
        comparison = compare_models(model, replacement)
        @test !comparison.override_compatible
        @test comparison.requires_binding_changes
    end
    changed_contract = AuthoringDistributedContractModel(model)
    @test !isequal(interface, model_interface(changed_contract))
    comparison = compare_models(model, changed_contract)
    @test !comparison.override_compatible
    @test any(difference.path == "variable_contracts.received" for difference in comparison.differences)
end

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

    reordered_policy = compare_models(
        AuthoringPolicyOrderModel((x=HoldLast(), y=Integrate())),
        AuthoringPolicyOrderModel((y=Integrate(), x=HoldLast())),
    )
    @test reordered_policy.override_compatible
    @test !reordered_policy.requires_binding_changes
    @test !reordered_policy.requires_reconfiguration
    @test isempty(reordered_policy.differences)

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

    for invalid_kernel in (AuthoringShortKernelModel(), AuthoringLongKernelModel())
        invalid_kernel_report = validate_model(invalid_kernel)
        @test !invalid_kernel_report.valid
        @test any(
            diagnostic -> diagnostic.code == :missing_run_method,
            invalid_kernel_report.diagnostics,
        )
    end
    for valid_kernel in (AuthoringVariadicKernelModel(), AuthoringFixedVariadicKernelModel())
        @test validate_model(valid_kernel).valid
        @test applicable(run!, valid_kernel, Status(), nothing, nothing, nothing)
    end

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
                      string(AuthoringInvalidMetadataModel),
        overridden_report.diagnostics,
    )
end
