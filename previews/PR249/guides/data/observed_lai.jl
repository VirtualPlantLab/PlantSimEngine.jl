# A measured-value alternative to ToyLAIModel, used by forcing_observations.md.
struct ObservedLAI <: PlantSimEngine.Examples.AbstractLai_DynamicModel end

PlantSimEngine.inputs_(::ObservedLAI) = NamedTuple()
PlantSimEngine.outputs_(::ObservedLAI) = (LAI=0.0,)
PlantSimEngine.environment_inputs_(::ObservedLAI) = (measured_LAI=0.0,)

function PlantSimEngine.run!(::ObservedLAI, status, environment, constants, context)
    status.LAI = environment.measured_LAI
    return nothing
end
