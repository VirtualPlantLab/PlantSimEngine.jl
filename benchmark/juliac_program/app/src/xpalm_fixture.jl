module XPalmFixture

using Dates
using PlantSimEngine
using XPalm
const PSE = PlantSimEngine
const Models = XPalm.Models

"""
    specs(; initial_depth=300.0, root_rate=0.3, root_stress=0.2,
            soil_humidity=0.15, field_capacity=0.23, crop_coefficient=1.0,
            TOpt1=25.0, TOpt2=30.0, TBase=15.0, TLim=40.0)

Original XPalm thermal-time, soil-water and root-growth kernels on each soil
object. FTSW's model-level `dep` supplies its published root-growth call. The
fixture does not redeclare that call or implement any scientific equation.
"""
function models(;
    initial_depth=300.0,
    root_rate=0.3,
    root_stress=0.2,
    soil_humidity=0.15,
    field_capacity=0.23,
    crop_coefficient=1.0,
    TOpt1=25.0,
    TOpt2=30.0,
    TBase=15.0,
    TLim=40.0,
)
    return (
        Models.DailyDegreeDays(;TOpt1,TOpt2,TBase,TLim),
        Models.FTSW(;ini_root_depth=initial_depth,H_0=soil_humidity,H_FC=field_capacity,KC=crop_coefficient),
        Models.RootGrowthFTSW(;ini_root_depth=initial_depth,ROOTS_GROWTH_DEPTH=root_rate,
            TRESH_FTSW_SLOW_ROOTS=root_stress),
    )
end

function specs(;kwargs...)
    map(models(;kwargs...),(:thermal_time,:soil_water,:root_growth)) do model,name
        ModelSpec(model;name,on=Many(kind=:soil),every=Day(1))
    end
end

"""Required, externally supplied soil inputs; retained as per-simulation data."""
initial(; ET0=2.5, aPPFD=1.0) = (; ET0, aPPFD)

"""
    rows(n; rain=3.0, rain_increment=0.5, Tmin=22.0, Tmax=31.0, Ri_PAR_f=8.0)

Daily plain forcing rows in the exact environment schema used by the original
XPalm kernels. Length and forcing values are data. `Ri_PAR_f` is daily incident
PAR energy in the units declared by XPalm's FTSW model (MJ m⁻² d⁻¹).
"""
function rows(n::Integer; rain=3.0, rain_increment=0.5, Tmin=22.0, Tmax=31.0, Ri_PAR_f=8.0)
    n >= 0 || throw(ArgumentError("negative number of forcing rows"))
    return [
        (Tmin=Tmin, Tmax=Tmax, Precipitations=rain + rain_increment * (i - 1), Ri_PAR_f=Ri_PAR_f)
        for i in 1:n
    ]
end

function _weather(forcing)
    isempty(forcing) && throw(ArgumentError("ordinary fixture requires at least one forcing row"))
    return Weather([
        Atmosphere(;
            date=DateTime(2025, 1, 1) + Day(i - 1), duration=Day(1),
            T=(row.Tmin + row.Tmax) / 2, Wind=1.0, Rh=0.6, P=100.0,
            row...,
        )
        for (i, row) in enumerate(forcing)
    ])
end

"""
    ordinary(ids, forcing; params=NamedTuple(), initial=XPalmFixture.initial(),
             newborn_id=nothing, birth_after=1, constants=Constants())

Prepare an ordinary PSE simulation once, then advance one step per forcing row.
When requested, register an additional soil object after `birth_after` completed
steps, including boundary zero. A newborn receives model-provided defaults and
its own supplied `initial` values. This is host-side population growth at a
step boundary; it does not exercise XPalm phytomer creation or whole-palm growth.
Returns the simulation with all output streams retained.
"""
function ordinary(
    ids,
    forcing;
    params=NamedTuple(),
    initial=XPalmFixture.initial(),
    newborn_id=nothing,
    birth_after=1,
    constants=Constants(),
)
    if !isnothing(newborn_id)
        0 <= birth_after <= length(forcing) || throw(ArgumentError("birth boundary outside timeline"))
        newborn_id in ids && throw(ArgumentError("duplicate newborn ID"))
    end
    scene = CompositeModel(
        (Object(id; kind=:soil, status=Status(initial)) for id in ids)...;
        applications=specs(; params...), environment=_weather(forcing),
    )
    simulation = PSE.run!(scene; steps=0, outputs=:all, constants)
    if !isnothing(newborn_id) && birth_after == 0
        PSE.register_object!(scene, Object(newborn_id; kind=:soil, status=Status(initial)))
    end
    for step in eachindex(forcing)
        PSE.step!(simulation)
        if !isnothing(newborn_id) && step == birth_after
            PSE.register_object!(scene, Object(newborn_id; kind=:soil, status=Status(initial)))
        end
    end
    return simulation
end

# Derive the complete canonical variable list from the existing contracts. Its
# fixed tuple supplies a stable comparison schema; population length stays in
# vectors and never becomes a tuple/type parameter.
const STATE_VARIABLES = let
    names = Symbol[]
    for spec in specs()
        append!(names, keys(PSE.inputs_(spec)))
        append!(names, keys(PSE.outputs_(spec)))
    end
    Tuple(sort!(unique!(names)))
end

_state_fingerprint(status) = NamedTuple{STATE_VARIABLES}(map(name -> status[name], STATE_VARIABLES))

"""All canonical status variables, with a stable schema and caller-specified ID order."""
function fingerprint(simulation::PSE.Simulation, ids)
    return (
        ids=collect(ids),
        states=[_state_fingerprint(PSE.final_state(simulation, ObjectId(id))) for id in ids],
    )
end

function fingerprint(ids::AbstractVector, statuses::AbstractVector)
    length(ids) == length(statuses) || throw(ArgumentError("unaligned fingerprint columns"))
    return (ids=copy(ids), states=[_state_fingerprint(status) for status in statuses])
end

end # module XPalmFixture
