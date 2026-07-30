"""
    ToySpatialEnvironment(cells; step_seconds=3600.0)

A minimal spatial environment for examples and tests.

`cells` maps cell ids to named tuples of environment variables. Objects select
a cell with geometry such as `(cell=:sun,)`. PlantSimEngine compiles that cell
id into a [`ToyEnvironmentHandle`](@ref), so sampling does not resolve geometry
inside the model kernel loop. An application configured with `sink=:cells` may
also commit an accepted named-tuple state to its bound cell.
"""
struct ToySpatialEnvironment{C,T} <:
       PlantSimEngine.EnvironmentAPI.AbstractEnvironmentBackend
    cells::C
    step_seconds::T
end

ToySpatialEnvironment(cells; step_seconds=3600.0) =
    ToySpatialEnvironment(cells, float(step_seconds))

"""
    ToyEnvironmentHandle

Opaque compiled handle returned by [`ToySpatialEnvironment`](@ref).
"""
struct ToyEnvironmentHandle
    cell::Symbol
    sink::Union{Nothing,Symbol}
end

PlantSimEngine.EnvironmentAPI.base_step_seconds(backend::ToySpatialEnvironment) =
    backend.step_seconds
PlantSimEngine.EnvironmentAPI.get_nsteps(::ToySpatialEnvironment) = 1

function PlantSimEngine.EnvironmentAPI.environment_variables(
    backend::ToySpatialEnvironment,
)
    isempty(backend.cells) && return Set{Symbol}()
    return Set(Symbol.(propertynames(first(values(backend.cells)))))
end

function PlantSimEngine.EnvironmentAPI.bind_environment(
    backend::ToySpatialEnvironment,
    object::PlantSimEngine.Object,
    context::PlantSimEngine.EnvironmentAPI.EnvironmentContext,
    config,
)
    object_geometry = PlantSimEngine.geometry(object)
    object_geometry isa NamedTuple && haskey(object_geometry, :cell) || error(
        "ToySpatialEnvironment needs `(cell=...,)` geometry for object " *
        "`$(object.id.value)`.",
    )
    cell = Symbol(object_geometry.cell)
    haskey(backend.cells, cell) || error(
        "ToySpatialEnvironment has no cell `$(cell)` for object " *
        "`$(object.id.value)`.",
    )
    sink =
        isnothing(config) || !haskey(config, :sink) ?
        nothing : Symbol(config.sink)
    isnothing(sink) || sink == :cells || error(
        "ToySpatialEnvironment only supports `sink=:cells`, got " *
        "`$(sink)`.",
    )
    return ToyEnvironmentHandle(cell, sink)
end

function PlantSimEngine.EnvironmentAPI.sample(
    backend::ToySpatialEnvironment,
    handle::ToyEnvironmentHandle,
    variable::Symbol,
    time,
)
    row = backend.cells[handle.cell]
    hasproperty(row, variable) || error(
        "ToySpatialEnvironment cell `$(handle.cell)` does not provide " *
        "variable `$(variable)`.",
    )
    return getproperty(row, variable)
end

function PlantSimEngine.EnvironmentAPI.sample(
    backend::ToySpatialEnvironment,
    handle::ToyEnvironmentHandle,
    state::NamedTuple,
    variable::Symbol,
    time,
)
    hasproperty(state, variable) || error(
        "ToySpatialEnvironment trial state does not provide variable " *
        "`$(variable)`.",
    )
    return getproperty(state, variable)
end

function PlantSimEngine.EnvironmentAPI.commit_environment!(
    backend::ToySpatialEnvironment,
    handle::ToyEnvironmentHandle,
    state::NamedTuple,
    time,
)
    handle.sink == :cells || error(
        "ToySpatialEnvironment handle for cell `$(handle.cell)` has no " *
        "commit sink.",
    )
    backend.cells[handle.cell] = state
    return nothing
end

PlantSimEngine.@process "toy_environment_reader" verbose = false
PlantSimEngine.@process "toy_environment_controller" verbose = false

"""
    ToyEnvironmentReaderModel()

Read temperature from the model-facing environment.
"""
struct ToyEnvironmentReaderModel <: AbstractToy_Environment_ReaderModel end

PlantSimEngine.inputs_(::ToyEnvironmentReaderModel) = NamedTuple()
PlantSimEngine.outputs_(::ToyEnvironmentReaderModel) = (temperature_seen=0.0,)
PlantSimEngine.environment_inputs_(::ToyEnvironmentReaderModel) = (T=0.0,)

function PlantSimEngine.run!(
    ::ToyEnvironmentReaderModel,
    status,
    environment,
    constants,
    context,
)
    status.temperature_seen = environment.T
    return nothing
end

"""
    ToyEnvironmentControllerModel(trial_temperature, accepted_temperature)

Demonstrate a typed trial environment followed by one accepted environment
commit and publication.
"""
struct ToyEnvironmentControllerModel{T} <:
       AbstractToy_Environment_ControllerModel
    trial_temperature::T
    accepted_temperature::T
end

function ToyEnvironmentControllerModel(trial_temperature, accepted_temperature)
    parameters = promote(
        float(trial_temperature),
        float(accepted_temperature),
    )
    return ToyEnvironmentControllerModel(parameters...)
end

PlantSimEngine.inputs_(::ToyEnvironmentControllerModel) = NamedTuple()
PlantSimEngine.dep(::ToyEnvironmentControllerModel) = (
    reader=Call(One(process=:toy_environment_reader)),
)
function PlantSimEngine.outputs_(model::ToyEnvironmentControllerModel)
    initial = zero(model.accepted_temperature)
    return (
        trial_temperature_seen=initial,
        accepted_temperature_seen=initial,
    )
end
PlantSimEngine.environment_outputs_(model::ToyEnvironmentControllerModel) = (
    T=zero(model.accepted_temperature),
)

function PlantSimEngine.run!(
    model::ToyEnvironmentControllerModel,
    status,
    environment,
    constants,
    context,
)
    trial_environment = (T=model.trial_temperature,)
    trial_target = only(run_call!(
        context,
        :reader;
        environment=trial_environment,
        publish=false,
    ))
    status.trial_temperature_seen = trial_target.status.temperature_seen

    accepted_environment = (T=model.accepted_temperature,)
    commit_environment!(context, accepted_environment)
    accepted_target = only(run_call!(
        context,
        :reader;
        environment=accepted_environment,
        publish=true,
    ))
    status.accepted_temperature_seen =
        accepted_target.status.temperature_seen
    return nothing
end
