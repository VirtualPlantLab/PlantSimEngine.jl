using Test
using PlantSimEngine
using PlantSimEngine.Authoring

include(joinpath(@__DIR__, "..", "src", "TwoProcessFixture.jl"))
using .TwoProcessFixture

@test validate_model(ConstantSignal(2.0f0); strict=true).valid
@test validate_model(LinearResponse(3.0f0); strict=true).valid

source_status = Status(signal=0.0f0)
PlantSimEngine.run!(
    ConstantSignal(2.0f0),
    source_status,
    NamedTuple(),
    nothing,
    nothing,
)
@test source_status.signal === 2.0f0

response_status = Status(signal=2.0f0, response=0.0f0)
PlantSimEngine.run!(
    LinearResponse(3.0f0),
    response_status,
    NamedTuple(),
    nothing,
    nothing,
)
@test response_status.response === 6.0f0

scenario = fixture_scenario(Float32)
@test validate_scenario(scenario; strict=true).valid
simulation = run!(scenario; steps=1, outputs=:none)
@test final_state(simulation).response === 6.0f0
