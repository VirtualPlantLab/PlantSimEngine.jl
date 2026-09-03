module TwoProcessFixture

using Dates
using PlantSimEngine

include("signal_supply/process.jl")
include("signal_supply/ConstantSignal.jl")
include("signal_response/process.jl")
include("signal_response/LinearResponse.jl")
include("scenario.jl")

export ConstantSignal, LinearResponse, fixture_scenario

end # module TwoProcessFixture
