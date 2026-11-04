"""
    PlantSimEngine.Compilation

Prepare a supported `CompositeModel` for a standalone application and build
that application with JuliaC. See [`prepare`](@ref) and [`compile`](@ref).
"""
module Compilation

import ..PlantSimEngine as PSE

export prepare, compile

struct PreparedSimulation{S,E,ST}
    simulation::S
    entries::E
    status::ST
end

function _unsupported(application::Symbol, reason)
    throw(ArgumentError("Cannot compile application $(repr(application)): $(reason)."))
end

function _check_scenario(plan)
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
        isempty(PSE.environment_inputs_(spec)) && isempty(PSE.environment_outputs_(spec)) ||
            _unsupported(application.id, "environment inputs or outputs are unsupported")
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
    _has_scalar_status(target.status) ||
        _unsupported(application.id, "status values must have concrete scalar numeric types")
    return nothing
end

"""
    prepare(model::CompositeModel; constants=Constants())

Prepare private execution state for a standalone application. Call this from
source at build time, with a fresh one-object model. The supported applications
run every step and use scalar numeric statuses and immutable `isbits` model
parameters and constants. Same-object live references use PSE's ordinary
bindings. Calls, initializers, temporal inputs, distributed or stream-only
outputs, environments, topology edits, and output histories are outside this
initial scope.

Advance the result with `continue!` or `step!`, and read it with `current_step`
and `final_state`. Each call to `prepare` starts with a private copy of the
model state.
"""
function prepare(model::PSE.CompositeModel; constants=PSE.Constants())
    length(model.registry.objects) == 1 ||
        throw(ArgumentError("Compilation requires one object with fixed topology."))
    isempty(model.instances) && isnothing(model.source_adapter) ||
        throw(ArgumentError("Compilation requires one ordinary object without instances or a topology adapter."))
    isnothing(model.environment) ||
        throw(ArgumentError("Compilation does not support a scenario environment."))
    isnothing(model.binding_cache) ||
        throw(ArgumentError("Compilation requires a fresh CompositeModel. Construct it again before preparing it."))
    isbits(constants) || throw(ArgumentError("Compilation requires isbits constants."))

    owned = deepcopy(model)
    prepared = PSE._prepare_scenario_plan(owned)
    _check_scenario(prepared.plan)
    simulation = PSE._prepare_simulation!(owned; steps=0, outputs=:none, constants)
    entries = Tuple((group.application, target)
        for group in simulation.execution_plan.groups
        for batch in group.batches for target in batch.targets)
    isempty(entries) && throw(ArgumentError("Compilation requires at least one scheduled application."))
    for (application, target) in entries
        _check_target(application, target)
    end
    status = only(PSE.model_objects(owned)).status
    _has_scalar_status(status) ||
        throw(ArgumentError("Compilation requires concrete scalar numeric object status values."))
    return PreparedSimulation(simulation, entries, status)
end

@inline function _check_topology(simulation)
    simulation.runtime_revision == simulation.model.runtime_revision ||
        throw(ArgumentError("Compiled simulation topology and bindings must stay fixed."))
    return nothing
end

@inline function _run_entries!(simulation, entries::Tuple, time::Float64)
    application, target = first(entries)
    PSE._run_model_execution_target_without_calls!(
        simulation.compiled, simulation.environment_bindings, application, target,
        time, simulation.constants, simulation.temporal_streams,
        simulation.output_retention, nothing, false,
    )
    _check_topology(simulation)
    return _run_entries!(simulation, Base.tail(entries), time)
end

@inline _run_entries!(simulation, ::Tuple{}, time::Float64) = nothing

function PSE.continue!(program::PreparedSimulation; steps::Integer=1)
    steps >= 0 || throw(ArgumentError("`steps` must be non-negative."))
    simulation = program.simulation
    _check_topology(simulation)
    iszero(steps) && return program
    final_step = Base.Checked.checked_add(simulation.current_step, Int(steps))
    for step in (simulation.current_step + 1):final_step
        simulation.compiled.execution_generation += UInt64(1)
        _run_entries!(simulation, program.entries, Float64(step))
        simulation.current_step = step
    end
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
