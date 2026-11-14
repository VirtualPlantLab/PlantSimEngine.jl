"""
    PlantSimEngine.Compilation

Prepare a supported `CompositeModel` for a standalone application and build
that application with JuliaC. See [`prepare`](@ref) and [`compile`](@ref).
"""
module Compilation

import ..PlantSimEngine as PSE

export prepare, compile

struct PreparedSimulation{S,ST}
    simulation::S
    status::ST
end

function _unsupported(application::Symbol, reason)
    throw(ArgumentError("Cannot compile application $(repr(application)): $(reason)."))
end

function _is_constant_environment(backend)
    backend isa PSE.GlobalConstant || return false
    source = PSE.environment_source(backend)
    return isnothing(source) || (isbits(source) && PSE.DataFormat(source) isa PSE.SingletonAlike)
end

function _check_scenario(model, plan)
    isempty(plan.call_plans) ||
        _unsupported(first(plan.call_plans).application_id, "calls or initializers are unsupported")
    distributed = plan.distributed_output_plans
    distributed isa PSE.NoCompiledDistributedOutputPlans ||
        _unsupported(first(distributed.plans).application_id, "distributed outputs are unsupported")
    for entry in plan.application_schedule.entries
        entry.kind === :always || _unsupported(entry.application_id, "it must run every step")
    end
    for application in plan.applications
        spec = application.spec
        isempty(application.ports.environment_output_names) ||
            _unsupported(application.id, "environment outputs are unsupported")
        backend = PSE._environment_backend_from_config(model, PSE.environment_config(spec))
        _is_constant_environment(backend) ||
            _unsupported(application.id, "environment must be a single immutable bits-valued row")
        :stream_only in values(PSE.output_routing(spec)) &&
            _unsupported(application.id, "stream-only outputs are unsupported")
    end
    return nothing
end

function _has_scalar_status(status)
    return all(PSE.refvalues(status)) do ref
        value = ref[]
        value isa Number && isbits(value) && ref isa Base.RefValue{typeof(value)}
    end
end

function _check_target(application, target)
    isbits(target.model) ||
        _unsupported(application.id, "model parameters must have an isbits type")
    isempty(target.input_bindings) ||
        _unsupported(application.id, "temporal input bindings are unsupported")
    isempty(target.bound_inputs) ||
        _unsupported(application.id, "collection-valued inputs are unsupported")
    _has_scalar_status(target.status_view.status) ||
        _unsupported(application.id, "status values must have concrete scalar numeric types")
    # Validate the same environment row that the canonical batch sampler uses.
    binding = target.environment_binding
    environment = isnothing(binding) ? nothing :
                  PSE._sample_compiled_global_environment(binding, 1)
    isbits(environment) ||
        _unsupported(application.id, "sampled environment must be an immutable bits-valued row")
    return nothing
end

"""
    prepare(model::CompositeModel; constants=Constants())

Prepare private execution state for a standalone application. Call this from
source at build time, with a fresh one-object model. The supported applications
run every step and use scalar numeric statuses and immutable `isbits` model
parameters and constants. Same-object live references and fixed environment
rows use PSE's ordinary bindings. A scenario or an application can provide
a single immutable bits-valued environment row, with optional field remapping.
Calls, initializers, temporal inputs, distributed or stream-only outputs,
environment commits, topology edits, and output histories are outside this
scope.

Advance the result with `continue!` or `step!`, and read it with `current_step`
and `final_state`. Each call to `prepare` starts with a private copy of the
model state.
"""
function prepare(model::PSE.CompositeModel; constants=PSE.Constants())
    length(model.registry.objects) == 1 ||
        throw(ArgumentError("Compilation requires one object with fixed topology."))
    isempty(model.instances) && isnothing(model.source_adapter) ||
        throw(ArgumentError("Compilation requires one ordinary object without instances or a topology adapter."))
    _is_constant_environment(PSE.environment_backend(model.environment)) ||
        throw(ArgumentError("The scenario environment must be a single immutable bits-valued row."))
    isnothing(model.binding_cache) ||
        throw(ArgumentError(
            "This CompositeModel already has live bindings. Construct it again before preparing it.",
        ))
    isbits(constants) || throw(ArgumentError("Compilation requires isbits constants."))

    owned = deepcopy(model)
    prepared = PSE._prepare_scenario_plan(owned)
    _check_scenario(owned, prepared.plan)
    simulation = PSE._prepare_simulation!(owned; steps=0, outputs=:none, constants)
    isempty(simulation.execution_plan.groups) &&
        throw(ArgumentError("Compilation requires at least one scheduled application."))
    for group in simulation.execution_plan.groups, batch in group.batches, target in batch.targets
        _check_target(group.application, target)
    end
    status = only(PSE.model_objects(owned)).status
    _has_scalar_status(status) ||
        throw(ArgumentError("Compilation requires concrete scalar numeric object status values."))
    plan = PSE._fixed_execution_plan(simulation.execution_plan)
    return PreparedSimulation(PSE._simulation_with_execution_plan(simulation, plan), status)
end

function PSE.continue!(program::PreparedSimulation; steps::Integer=1)
    PSE.continue!(program.simulation; steps)
    return program
end

PSE.step!(program::PreparedSimulation) = PSE.continue!(program; steps=1)
PSE.current_step(program::PreparedSimulation) = PSE.current_step(program.simulation)
PSE.final_state(program::PreparedSimulation) = NamedTuple(program.status)

"""
    compile(app_project; destination, name="simulation")

Build a named Julia application project with an `@main` entry point as a
JuliaC `safe` executable. Load `JuliaC` and PlantSimEngine in the build
session. The build requires Julia 1.13 or later and a C toolchain. Use
[`prepare`](@ref) in the application's source to prepare its scenario.

`destination` must be a new directory. Return a named tuple containing the
absolute `directory` and `executable` paths. Keep the full bundle together
when moving the executable.
"""
function compile(app_project::AbstractString; destination::AbstractString, name::AbstractString="simulation")
    VERSION >= v"1.13" || throw(ArgumentError("Safe application builds require Julia 1.13 or later."))
    extension = Base.get_extension(PSE, :PlantSimEngineJuliaCExt)
    isnothing(extension) && throw(ArgumentError("Load JuliaC before calling Compilation.compile."))
    return extension.build_bundle(app_project, destination, name)
end

end # module Compilation
