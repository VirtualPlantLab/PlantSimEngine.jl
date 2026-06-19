using Dates
using DataFrames
using PlantBiophysics
using PlantMeteo
using Random

function _plantbiophysics_forcing_set(n::Int)
    Random.seed!(1)
    length_range = 10_000
    ranges = (
        T=range(18, 40; length=length_range),
        Wind=range(0.5, 20; length=length_range),
        P=range(90, 101; length=length_range),
        Rh=range(0.1, 0.98; length=length_range),
        Ca=range(360, 900; length=length_range),
        JMaxRef=range(200.0, 300.0; length=length_range),
        VcMaxRef=range(150.0, 250.0; length=length_range),
        RdRef=range(0.3, 2.0; length=length_range),
        Ra_SW_f=range(10, 500; length=length_range),
        sky_fraction=range(0.0, 1.0; length=length_range),
        d=range(0.001, 0.5; length=length_range),
        TPURef=range(5.0, 20.0; length=length_range),
        g0=range(0.001, 2.0; length=length_range),
        g1=range(0.5, 15.0; length=length_range),
    )
    columns = (; (
        name => [rand(values) for _ in 1:n]
        for (name, values) in pairs(ranges)
    )...)
    return DataFrame(columns)
end

function _plantbiophysics_leaf_scene(row)
    return PlantBiophysics.leaf_scene(
        Monteith(),
        Fvcb(
            VcMaxRef=row.VcMaxRef,
            JMaxRef=row.JMaxRef,
            RdRef=row.RdRef,
            TPURef=row.TPURef,
        ),
        Medlyn(row.g0, row.g1);
        status=Status(
            Ra_SW_f=row.Ra_SW_f,
            sky_fraction=row.sky_fraction,
            aPPFD=row.Ra_SW_f * 0.48 * 4.57,
            d=row.d,
        ),
        environment=Atmosphere(
            T=row.T,
            Wind=row.Wind,
            P=row.P,
            Rh=row.Rh,
            Cₐ=row.Ca,
            duration=Hour(1),
        ),
    )
end

function setup_benchmark_plantbiophysics_batch(; n=100)
    forcing = _plantbiophysics_forcing_set(n)
    return [_plantbiophysics_leaf_scene(row) for row in eachrow(forcing)]
end

function benchmark_plantbiophysics_batch(scenes)
    constants = Constants()
    for scene in scenes
        run!(scene; constants=constants, outputs=:none)
    end
    return nothing
end

function benchmark_plantbiophysics()
    scenes = setup_benchmark_plantbiophysics_batch()
    return benchmark_plantbiophysics_batch(scenes)
end
