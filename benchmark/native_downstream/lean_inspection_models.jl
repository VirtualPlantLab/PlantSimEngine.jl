# Main-owned fixture kernels match readable-source support for script-defined models.
using PlantSimEngine

PlantSimEngine.@process "lean_readable_source" verbose=false
struct LeanReadableSource{T} <: AbstractLean_Readable_SourceModel
    gain::T
end
PlantSimEngine.inputs_(::LeanReadableSource) = NamedTuple()
PlantSimEngine.outputs_(model::LeanReadableSource) = (value=zero(model.gain), visits=0)
PlantSimEngine.environment_inputs_(model::LeanReadableSource) = (temperature=zero(model.gain),)
function PlantSimEngine.run!(model::LeanReadableSource, status, environment, constants, context)
    status.value += model.gain * environment.temperature
    status.visits += 1
    return nothing
end
Main.CompiledRegionsExperiment.region_effects(::Type{<:LeanReadableSource}) = :local_ports

PlantSimEngine.@process "lean_readable_consumer" verbose=false
struct LeanReadableConsumer{T} <: AbstractLean_Readable_ConsumerModel end
PlantSimEngine.inputs_(::LeanReadableConsumer{T}) where {T} = (supply=PlantSimEngine.Required(T),)
PlantSimEngine.outputs_(::LeanReadableConsumer{T}) where {T} = (observed=zero(T), visits=0)
function PlantSimEngine.run!(model::LeanReadableConsumer, status, environment, constants, context)
    status.observed = status.supply * 2
    status.visits += 1
    return nothing
end
# This consumer deliberately has no optimization capability. It exercises an
# ordinary batch interleaved with a genuinely lean source batch in one plan.
