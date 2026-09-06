using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "contract_defaults" verbose = false

struct ContractDefaultsModel <: AbstractContract_DefaultsModel end
struct ContractExplicitModel <: AbstractContract_DefaultsModel end

PlantSimEngine.inputs_(::ContractDefaultsModel) = NamedTuple()
PlantSimEngine.outputs_(::ContractDefaultsModel) = (value=0,)
PlantSimEngine.inputs_(::ContractExplicitModel) = NamedTuple()
PlantSimEngine.outputs_(::ContractExplicitModel) = (value=0,)
PlantSimEngine.timespec(::Type{<:ContractExplicitModel}) = ClockSpec(2, 1)
PlantSimEngine.output_policy(::Type{<:ContractExplicitModel}) = (value=Aggregate(),)
PlantSimEngine.timestep_hint(::Type{<:ContractExplicitModel}) = (preferred=Dates.Hour(2),)
PlantSimEngine.environment_hint(::Type{<:ContractExplicitModel}) = (window=Dates.Hour(2),)
PlantSimEngine.environment_inputs_(::ContractExplicitModel) = (T=0,)
PlantSimEngine.environment_outputs_(::ContractExplicitModel) = (T=0,)

PlantSimEngine.@process "contract_semantic_source" verbose = false
PlantSimEngine.@process "contract_semantic_consumer" verbose = false

struct ContractGroundSource <: AbstractContract_Semantic_SourceModel end
struct ContractPlantSource <: AbstractContract_Semantic_SourceModel end
struct ContractUnspecifiedSource <: AbstractContract_Semantic_SourceModel end
struct ContractDistributedGroundSource <: AbstractContract_Semantic_SourceModel end
struct ContractDistributedPlantSource <: AbstractContract_Semantic_SourceModel end
struct ContractPlantConsumer <: AbstractContract_Semantic_ConsumerModel end
struct ContractUnspecifiedConsumer <: AbstractContract_Semantic_ConsumerModel end
struct ContractUnknownVariable <: AbstractContract_Semantic_SourceModel end
struct ContractInvalidDeclaration <: AbstractContract_Semantic_SourceModel end

PlantSimEngine.inputs_(::Union{
    ContractGroundSource,
    ContractPlantSource,
    ContractUnspecifiedSource,
    ContractDistributedGroundSource,
    ContractDistributedPlantSource,
    ContractUnknownVariable,
    ContractInvalidDeclaration,
}) = NamedTuple()
PlantSimEngine.outputs_(::Union{
    ContractGroundSource,
    ContractPlantSource,
    ContractUnspecifiedSource,
    ContractUnknownVariable,
    ContractInvalidDeclaration,
}) = (aPPFD=0.0,)
PlantSimEngine.outputs_(::Union{
    ContractDistributedGroundSource,
    ContractDistributedPlantSource,
}) = NamedTuple()
PlantSimEngine.inputs_(::Union{
    ContractPlantConsumer,
    ContractUnspecifiedConsumer,
}) = (aPPFD=Required(Float64),)
PlantSimEngine.outputs_(::Union{
    ContractPlantConsumer,
    ContractUnspecifiedConsumer,
}) = (observed=0.0,)

const GROUND_DAILY_PHOTONS = VariableContract(
    unit=:mol_photon,
    basis=:ground_area,
    temporal=:day,
    aggregation=:total,
    extent=:intensive,
)
const PLANT_DAILY_PHOTONS = VariableContract(
    unit=:mol_photon,
    basis=:plant,
    temporal=:day,
    aggregation=:total,
    extent=:extensive,
)

PlantSimEngine.variable_contracts_(::ContractGroundSource) =
    (aPPFD=GROUND_DAILY_PHOTONS,)
PlantSimEngine.variable_contracts_(::ContractPlantSource) =
    (aPPFD=PLANT_DAILY_PHOTONS,)
PlantSimEngine.variable_contracts_(::ContractDistributedGroundSource) =
    (aPPFD=GROUND_DAILY_PHOTONS,)
PlantSimEngine.variable_contracts_(::ContractDistributedPlantSource) =
    (aPPFD=PLANT_DAILY_PHOTONS,)
PlantSimEngine.variable_contracts_(::ContractPlantConsumer) =
    (aPPFD=PLANT_DAILY_PHOTONS,)
PlantSimEngine.variable_contracts_(::ContractUnknownVariable) =
    (unknown=PLANT_DAILY_PHOTONS,)
PlantSimEngine.variable_contracts_(::ContractInvalidDeclaration) =
    (aPPFD="mol photons",)

function PlantSimEngine.run!(
    ::Union{ContractGroundSource,ContractPlantSource,ContractUnspecifiedSource},
    status,
    environment,
    constants,
    context,
)
    status.aPPFD = 12.0
end

function PlantSimEngine.run!(
    ::Union{ContractPlantConsumer,ContractUnspecifiedConsumer},
    status,
    environment,
    constants,
    context,
)
    status.observed = status.aPPFD
end

@testset "direct model trait defaults" begin
    model = ContractDefaultsModel()
    @test process(model) == :contract_defaults
    @test application_name(ModelSpec(model)) === nothing
    default_scene = CompositeModel(model)
    @test only(explain_applications(Advanced.refresh_bindings!(default_scene))).application_id ==
          :contract_defaults
    @test timespec(model) == ClockSpec(1.0, 0.0)
    @test output_policy(model) == NamedTuple()
    @test timestep_hint(model) === nothing
    @test environment_hint(model) === nothing
    @test PlantSimEngine.environment_inputs_(model) == NamedTuple()
    @test PlantSimEngine.environment_outputs_(model) == NamedTuple()

    explicit = ContractExplicitModel()
    @test timespec(explicit) == ClockSpec(2, 1)
    @test output_policy(explicit).value isa Aggregate
    @test timestep_hint(explicit) == (preferred=Dates.Hour(2),)
    @test environment_hint(explicit) == (window=Dates.Hour(2),)
    @test PlantSimEngine.environment_inputs_(explicit) == (T=0,)
    @test PlantSimEngine.environment_outputs_(explicit) == (T=0,)
    @test variable_contracts(model) == NamedTuple()
end

function _contract_scene(source, consumer)
    return CompositeModel(
        Object(:plant; scale=:Plant);
        applications=(
            ModelSpec(source; name=:source, on=One(scale=:Plant)),
            ModelSpec(consumer; name=:consumer, on=One(scale=:Plant)),
        ),
    )
end

function _distributed_contract_scene(source, consumer)
    return CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant; scale=:Plant, parent=:scene);
        applications=(
            ModelSpec(
                source;
                name=:source,
                on=One(scale=:Scene),
                outputs_to=(
                    plants=OutputTo(
                        Many(scale=:Plant, within=SceneScope());
                        vars=(aPPFD=Default(0.0),),
                    ),
                ),
            ),
            ModelSpec(consumer; name=:consumer, on=One(scale=:Plant)),
        ),
    )
end

@testset "scientific variable contracts" begin
    @test_throws ArgumentError VariableContract(unit="mol_photon")
    @test_throws ArgumentError VariableContract(
        unit=:mol_photon,
        basis="ground_area",
    )
    @test variable_contracts(ContractPlantSource()) ==
          (aPPFD=PLANT_DAILY_PHOTONS,)

    compatible = _contract_scene(ContractPlantSource(), ContractPlantConsumer())
    Advanced.refresh_bindings!(compatible)
    run!(compatible; outputs=:none)
    @test model_object(compatible, :plant).status.observed == 12.0

    incompatible = _contract_scene(ContractGroundSource(), ContractPlantConsumer())
    @test_throws "Incompatible variable contracts" Advanced.refresh_bindings!(
        incompatible,
    )

    missing_producer =
        _contract_scene(ContractUnspecifiedSource(), ContractPlantConsumer())
    @test_throws "source output `aPPFD` from application `source` declares none" Advanced.refresh_bindings!(
        missing_producer,
    )

    missing_consumer =
        _contract_scene(ContractPlantSource(), ContractUnspecifiedConsumer())
    @test_throws "consumer declares no contract" Advanced.refresh_bindings!(
        missing_consumer,
    )

    distributed = _distributed_contract_scene(
        ContractDistributedPlantSource(),
        ContractPlantConsumer(),
    )
    Advanced.refresh_bindings!(distributed)
    distributed_mismatch = _distributed_contract_scene(
        ContractDistributedGroundSource(),
        ContractPlantConsumer(),
    )
    @test_throws "Incompatible variable contracts" Advanced.refresh_bindings!(
        distributed_mismatch,
    )

    unknown_contract = CompositeModel(
        Object(:plant; scale=:Plant);
        applications=(
            ModelSpec(
                ContractUnknownVariable();
                name=:unknown,
                on=One(scale=:Plant),
            ),
        ),
    )
    @test_throws "declares unknown variable" Advanced.refresh_bindings!(
        unknown_contract,
    )
    @test_throws "must contain only `VariableContract` values" variable_contracts(
        ContractInvalidDeclaration(),
    )

    descriptor = PlantSimEngine.Authoring.to_dict(
        PlantSimEngine.Authoring.describe_model(ContractPlantSource()),
    )
    @test descriptor["interface"]["variableContracts"]["aPPFD"] == Dict(
        "unit" => "mol_photon",
        "basis" => "plant",
        "temporal" => "day",
        "aggregation" => "total",
        "extent" => "extensive",
    )
end
