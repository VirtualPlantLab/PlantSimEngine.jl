@noinline function _probe_kernel_loop!(target, environment, constants, repetitions)
    for _ in 1:repetitions
        PSE.run!(target.model, target.status, environment, constants, target.context)
    end
    return nothing
end

function direct_kernel_gate(; repetitions=1024)
    sim = PSE.run!(fixture_builder(; nobjects=1, nmodels=4); steps=0, outputs=:none)
    batch = first(sim.execution_plan.batches)
    target = first(batch.targets)
    environment = PSE._model_execution_batch_environment(batch.environment_provider,
        sim.environment_bindings, batch.application, 1)
    _probe_kernel_loop!(target, environment, sim.constants, repetitions)
    bytes = @allocated _probe_kernel_loop!(target, environment, sim.constants, repetitions)
    return (; repetitions, allocated_bytes=bytes, model_type=string(typeof(target.model)))
end
