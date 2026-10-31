module LeanBoundaryProbe
using PlantSimEngine
const Driver = Main.LeanNativeDriver

@noinline function probe(batch::B, simulation::S; iterations=1024) where {B,S}
    environment = PlantSimEngine._model_execution_batch_environment(
        batch.environment_provider, simulation.environment_bindings,
        batch.application, 1)
    leaf = @timed for _ in 1:iterations
        Driver._numerical_rows!(batch, environment, simulation.constants, 1)
    end
    control = @timed for _ in 1:iterations
        PlantSimEngine._run_model_execution_batch!(batch, simulation.compiled,
            simulation.environment_bindings, 1, simulation.constants,
            simulation.temporal_streams, simulation.output_retention)
    end
    return (leaf_seconds=leaf.time, leaf_bytes=leaf.bytes,
        control_seconds=control.time, control_bytes=control.bytes)
end
end
