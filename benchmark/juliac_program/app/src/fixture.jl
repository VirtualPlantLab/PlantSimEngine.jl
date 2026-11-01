module NativeFixture

using Dates
using PlantSimEngine

# Deliberately small scientific kernels. Both executors call these same methods;
# there is no independent reimplementation of either numerical equation.
PlantSimEngine.@process "native_fixture_assimilation" verbose = false
struct Assimilation{T} <: AbstractNative_Fixture_AssimilationModel
    efficiency::T
end

PlantSimEngine.inputs_(::Assimilation{T}) where {T} = (leaf_area=Default(one(T)),)
PlantSimEngine.outputs_(::Assimilation{T}) where {T} = (carbon=zero(T),)
PlantSimEngine.environment_inputs_(::Assimilation{T}) where {T} = (T=zero(T),)

function PlantSimEngine.run!(model::Assimilation, status, environment, constants, context)
    status.carbon = model.efficiency * status.leaf_area * environment.T
    return nothing
end

PlantSimEngine.@process "native_fixture_accumulation" verbose = false
struct Accumulation{T} <: AbstractNative_Fixture_AccumulationModel
    conversion::T
end

PlantSimEngine.inputs_(::Accumulation{T}) where {T} = (carbon=Required(T),)
PlantSimEngine.outputs_(::Accumulation{T}) where {T} = (biomass=zero(T),)

function PlantSimEngine.run!(model::Accumulation, status, environment, constants, context)
    status.biomass += model.conversion * status.carbon
    return nothing
end

"""Authored in reverse dependency order to exercise declaration-based ordering."""
function specs(; efficiency=0.5, conversion=0.25)
    return (
        ModelSpec(Accumulation(conversion); name=:accumulation, on=Many(kind=:leaf), every=Day(1)),
        ModelSpec(Assimilation(efficiency); name=:assimilation, on=Many(kind=:leaf), every=Day(1)),
    )
end

"""
    ordinary(ids, rows; efficiency=0.5, conversion=0.25, leaf_area=1.0, biomass=0.0)

Execute the ordinary CompositeModel/Object path with retained outputs. `rows`
contains one `NamedTuple` with a `T` field per day, in chronological order. The
other meteorological fields are fixed fixture inputs, unused by these kernels.
"""
function ordinary(ids, rows; efficiency=0.5, conversion=0.25, leaf_area=1.0, biomass=0.0)
    start = DateTime(2025, 1, 1)
    weather = Weather([
        Atmosphere(
            date=start + Day(i - 1), T=row.T, Wind=1.0, Rh=0.5,
            P=100.0, Ri_SW_f=100.0, duration=Day(1),
        )
        for (i, row) in enumerate(rows)
    ])
    scene = CompositeModel(
        (Object(id; kind=:leaf, status=Status(leaf_area=leaf_area, biomass=biomass)) for id in ids)...;
        applications=specs(; efficiency, conversion),
        environment=weather,
    )
    return run!(scene; steps=length(rows), outputs=:all)
end

end # module NativeFixture
