"""
    ToySpatialEnvironment(cells; step_seconds=3600.0)

A minimal read-only spatial environment for examples and tests.

`cells` maps cell ids to named tuples of environment variables. Objects select
a cell with geometry such as `(cell=:sun,)`. PlantSimEngine compiles that cell
id into a [`ToyEnvironmentHandle`](@ref), so sampling does not resolve geometry
inside the model kernel loop.
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
    return ToyEnvironmentHandle(cell)
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

