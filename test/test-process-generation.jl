using Test

@testset "@process authoring tutorial" begin
    tutorial = PlantSimEngine._process_model_tutorial(
        "tutorial_contract_probe",
        :AbstractTutorial_Contract_ProbeModel,
    )

    @test occursin("struct MyTutorial_Contract_ProbeModel{T}", tutorial)
    @test occursin("inputs_", tutorial)
    @test occursin("outputs_", tutorial)
    @test occursin("environment_inputs_", tutorial)
    @test occursin("environment_outputs_", tutorial)
    @test occursin("variable_contracts_", tutorial)
    @test occursin("VariableContract", tutorial)
    @test occursin("return nothing", tutorial)
    @test !occursin("Float64", tutorial)
    @test !occursin("-Inf", tutorial)
    @test !occursin("environment.CO2", tutorial)
end

PlantSimEngine.@process "tutorial_contract_probe" verbose = false

struct TutorialContractProbeModel{T} <: AbstractTutorial_Contract_ProbeModel
    a::T
end

PlantSimEngine.inputs_(::TutorialContractProbeModel) = (X=Required(Real),)
PlantSimEngine.outputs_(model::TutorialContractProbeModel) = (Y=zero(model.a),)
PlantSimEngine.environment_inputs_(model::TutorialContractProbeModel) = (
    forcing=zero(model.a),
)
PlantSimEngine.environment_outputs_(::TutorialContractProbeModel) = NamedTuple()
const TUTORIAL_CONTRACT = VariableContract(
    unit=:dimensionless,
    basis=:object,
    temporal=:step,
    aggregation=:instantaneous,
    extent=:intensive,
)
PlantSimEngine.variable_contracts_(::TutorialContractProbeModel) = (
    X=TUTORIAL_CONTRACT,
    forcing=TUTORIAL_CONTRACT,
    Y=TUTORIAL_CONTRACT,
)

function PlantSimEngine.run!(
    model::TutorialContractProbeModel,
    status,
    environment,
    constants,
    context,
)
    status.Y = model.a * environment.forcing + status.X
    return nothing
end

@testset "@process tutorial pattern executes generically" begin
    model = TutorialContractProbeModel(2.0f0)
    status = Status(X=1.0f0, Y=0.0f0)

    @test PlantSimEngine.run!(
        model,
        status,
        (forcing=3.0f0,),
        nothing,
        nothing,
    ) === nothing
    @test status.Y === 7.0f0
    @test inputs(model) == (:X,)
    @test outputs(model) == (:Y,)
    @test environment_inputs(model) == (:forcing,)
    @test environment_outputs(model) == ()
    @test variable_contracts(model).Y == TUTORIAL_CONTRACT
end
