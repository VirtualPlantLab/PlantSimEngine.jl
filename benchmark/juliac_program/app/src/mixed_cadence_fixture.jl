module MixedCadenceFixture

using Dates
using PlantSimEngine
import MultiScaleTreeGraph as MTG
import ..ReusableProgram as RP

const PSE = PlantSimEngine
const ROW = (duration=Hour(1),)
const INITIAL = (Scene=NamedTuple(), Plant=NamedTuple())
const OBJECTS = map(_ -> typeof((object_id=ObjectId(1), values=NamedTuple()))[], INITIAL)
const NativeNode = MTG.Node{MTG.NodeMTG,typeof(NamedTuple())}

PSE.@process "native_hourly_source" verbose=false
struct HourlySource <: AbstractNative_Hourly_SourceModel end
PSE.outputs_(::HourlySource) = (hourly_total=0,)
PSE.run!(::HourlySource, status, environment, constants, context) =
    (status.hourly_total += 1; nothing)

PSE.@process "native_cadence_readout" verbose=false
struct CadenceReadout <: AbstractNative_Cadence_ReadoutModel end
PSE.inputs_(::CadenceReadout) = (hourly_total=Required(Int), prior_total=Default(0))
PSE.outputs_(::CadenceReadout) = (current=0, previous=0)
function PSE.run!(::CadenceReadout, status, environment, constants, context)
    status.current = status.hourly_total
    status.previous = status.prior_total
    PSE.run_call!(context, :tick; publish=true)
    return nothing
end

PSE.@process "native_cadence_tick" verbose=false
struct CadenceTick <: AbstractNative_Cadence_TickModel end
PSE.outputs_(::CadenceTick) = (ticks=0,)
PSE.run!(::CadenceTick, status, environment, constants, context) =
    (status.ticks += 1; nothing)

models() = (CadenceReadout(), HourlySource(), CadenceTick())

function tree()
    root = NativeNode(1, nothing, NativeNode[], MTG.NodeMTG(:/, :Scene, 1, 0), NamedTuple(), nothing)
    plant = NativeNode(2, nothing, NativeNode[], MTG.NodeMTG(:+, :Plant, 1, 1), NamedTuple(), nothing)
    MTG.addchild!(root, plant)
    return root
end

function scene(; readout_every=Day(1))
    readout, source, tick = models()
    previous = PreviousTimeStep(:prior_total) => One(within=Self(), application=:hourly, var=:hourly_total)
    # Declare the consumer first so the compiler has to order the live input.
    applications = (
        ModelSpec(readout; name=:readout, on=Many(scale=:Plant), every=readout_every,
            inputs=(previous,), calls=(tick=One(within=Self(), application=:tick),)),
        ModelSpec(source; name=:hourly, on=Many(scale=:Plant), every=Hour(1)),
        ModelSpec(tick; name=:tick, on=Many(scale=:Plant)),
    )
    return CompositeModel(tree(); applications, environment=ROW)
end

prepare(; kwargs...) = RP.prepare(scene(; kwargs...); initial=INITIAL)

instantiate(program) = RP.instantiate(program, models(), tree();
    initial=INITIAL, objects=OBJECTS, retain=true)

function advance!(state, steps::Int)
    steps >= 0 || throw(ArgumentError("negative cadence duration"))
    for _ in 1:steps
        RP.step!(state, ROW)
    end
    return state
end

end
