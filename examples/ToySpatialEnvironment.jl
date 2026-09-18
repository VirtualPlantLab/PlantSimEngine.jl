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
    ToyEnvironmentControllerModel(; increment=1.0, threshold=22.0, max_iterations=100)

Start from the environment temperature and repeatedly add `increment` until
the reader returns a temperature strictly above `threshold`. Commit that
temperature and publish the reader's result only after the loop succeeds.
This arbitrary rule teaches iteration and environment updates; it is not a
physical temperature model. `max_iterations` limits the number of trial calls.
"""
struct ToyEnvironmentControllerModel{T} <:
       AbstractToy_Environment_ControllerModel
    increment::T
    threshold::T
    max_iterations::Int
end

function ToyEnvironmentControllerModel(;
    increment=1.0,
    threshold=22.0,
    max_iterations::Integer=100,
)
    increment, threshold = promote(float(increment), float(threshold))
    isfinite(increment) && increment > zero(increment) || throw(
        ArgumentError("increment must be finite and positive."),
    )
    isfinite(threshold) || throw(ArgumentError("threshold must be finite."))
    max_iterations > 0 || throw(ArgumentError("max_iterations must be positive."))
    return ToyEnvironmentControllerModel(increment, threshold, Int(max_iterations))
end

PlantSimEngine.inputs_(::ToyEnvironmentControllerModel) = NamedTuple()
PlantSimEngine.dep(::ToyEnvironmentControllerModel) = (
    reader=Call(One(process=:toy_environment_reader)),
)
function PlantSimEngine.outputs_(model::ToyEnvironmentControllerModel)
    initial = zero(model.threshold)
    return (
        initial_temperature=initial,
        iterations=0,
        accepted_temperature_seen=initial,
    )
end
PlantSimEngine.environment_inputs_(model::ToyEnvironmentControllerModel) = (
    T=zero(model.threshold),
)
PlantSimEngine.environment_outputs_(model::ToyEnvironmentControllerModel) = (
    T=zero(model.threshold),
)

function PlantSimEngine.run!(
    model::ToyEnvironmentControllerModel,
    status,
    environment,
    constants,
    context,
)
    temperature = environment.T
    status.initial_temperature = temperature
    status.iterations = 0

    for iteration in 1:model.max_iterations
        trial_target = only(run_call!(
            context,
            :reader;
            environment=(T=temperature,),
            publish=false,
        ))
        status.iterations = iteration

        if trial_target.status.temperature_seen > model.threshold
            commit_environment!(context, (T=temperature,))
            accepted_target = only(run_call!(
                context, :reader; environment=(T=temperature,), publish=true,
            ))
            status.accepted_temperature_seen =
                accepted_target.status.temperature_seen
            return nothing
        end

        # A real solver would calculate its next estimate from model results.
        temperature = trial_target.status.temperature_seen + model.increment
    end

    error("Temperature did not exceed the threshold within $(model.max_iterations) iterations.")
end
