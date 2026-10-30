module LeanNativeInspection

using PlantSimEngine

const PSE = PlantSimEngine
const Driver = Main.LeanNativeDriver

# Readable source execution intentionally uses ordinary per-object snapshots.
# Sampling still occurs once at the same batch boundary, with the same provider
# and publication flag as normal execution. LeanTargetView materializes a rich
# target only when this cold inspection/execution path actually requests it.
# No numerical column execution is claimed for the generated source path.
function PSE._compiled_source_prepare_batch(simulation::PSE.Simulation,
    batch::Driver.LeanNumericalBatch, time::Real)
    environment = PSE._model_execution_batch_environment(batch.environment_provider,
        simulation.environment_bindings, batch.application, time)
    return environment, batch.output_publication.enabled
end

end # module
