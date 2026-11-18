module PSEThirtyProducerControl
import PlantSimEngine as PSE
include("native_preparation.jl")
using .NativePreparation: close_registry, RuntimeTypes, InputTrace, remember!, batch_schema
include("distributed_growth.jl")
include("prepare.jl")
const STATE = prepare_control()
function (@main)(args)
    isempty(args) || return Cint(2)
    checkpoint(STATE, 0) || return Cint(10)
    for day in 1:3
        PSE.step!(STATE.simulation)
        checkpoint(STATE, day) || return Cint(10 + day)
    end
    return Cint(0)
end
end
