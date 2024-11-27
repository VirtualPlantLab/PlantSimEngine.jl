#TODO REMOVE SOME OF THOSE BITS
using Pkg
#Pkg.develop("PlantSimEngine")
using PlantSimEngine
using Statistics
using DataFrames
using CSV
using Random
using PlantBiophysics
using BenchmarkTools
using Test

function benchmark_plantbiophysics()

    Random.seed!(1) # Set random seed
    microbenchmark_steps = 100 # Number of times the microbenchmark is run
    microbenchmark_evals = 1 # N. times each sample is run to be sure of the output
    N = 100 # Number of timesteps simulated for each microbenchmark step

    length_range = 10000
    Rs = range(10, 500, length=length_range)
    Ta = range(18, 40, length=length_range)
    Wind = range(0.5, 20, length=length_range)
    P = range(90, 101, length=length_range)
    Rh = range(0.1, 0.98, length=length_range)
    Ca = range(360, 900, length=length_range)
    skyF = range(0.0, 1.0, length=length_range)
    d = range(0.001, 0.5, length=length_range)
    Jmax = range(200.0, 300.0, length=length_range)
    Vmax = range(150.0, 250.0, length=length_range)
    Rd = range(0.3, 2.0, length=length_range)
    TPU = range(5.0, 20.0, length=length_range)
    g0 = range(0.001, 2.0, length=length_range)
    g1 = range(0.5, 15.0, length=length_range)
    vars = hcat([Ta, Wind, P, Rh, Ca, Jmax, Vmax, Rd, Rs, skyF, d, TPU, g0, g1])

    set = [rand.(vars) for i = 1:N]
    set = reshape(vcat(set...), (length(set[1]), length(set)))'
    name = [
        "T",
        "Wind",
        "P",
        "Rh",
        "Ca",
        "JMaxRef",
        "VcMaxRef",
        "RdRef",
        "Rs",
        "sky_fraction",
        "d",
        "TPURef",
        "g0",
        "g1",
    ]
    set = DataFrame(set, name)
    @. set[!, :vpd] = e_sat(set.T) - vapor_pressure(set.T, set.Rh)
    @. set[!, :PPFD] = set.Rs * 0.48 * 4.57
    set


    constants = Constants()
    time_PB = []
    for i = 1:N
        leaf = ModelList(
            energy_balance=Monteith(),
            photosynthesis=Fvcb(
                VcMaxRef=set.VcMaxRef[i],
                JMaxRef=set.JMaxRef[i],
                RdRef=set.RdRef[i],
                TPURef=set.TPURef[i],
            ),
            stomatal_conductance=Medlyn(set.g0[i], set.g1[i]),
            status=(
                Rₛ=set.Rs[i],
                sky_fraction=set.sky_fraction[i],
                PPFD=set.PPFD[i],
                d=set.d[i],
            ),
        )
        deps = PlantSimEngine.dep(leaf)
        meteo = Atmosphere(T=set.T[i], Wind=set.Wind[i], P=set.P[i], Rh=set.Rh[i], Cₐ=set.Ca[i])
        st = PlantMeteo.row_struct(leaf.status[1])
        b_PB = @benchmark run!($leaf, $deps, 1, $st, $meteo, $constants, nothing; executor = ThreadedEx()) evals = microbenchmark_evals samples = microbenchmark_steps
        append!(time_PB, b_PB.times .* 1e-9) # transform in seconds
    end
    return time_PB
end

@testset "PlantBiophysics benchmark" begin

    time_PB = benchmark_plantbiophysics()
    
    #statsPB = (mean(time_PB), median(time_PB), Statistics.std(time_PB), findmin(time_PB), findmax(time_PB))
    mean(time_PB)
    @test mean(time_PB) > 1000000000000000
    #TODO deal with results
end


#=
function run_plantbiophysics()


    Rs = 10.0
    Ta = 18.0
    Wind = 0.5
    P = 90.0
    Rh = 0.1
    Ca = 360.0
    skyF = 0.0
    d = 0.001
    Jmax = 200.0
    Vmax = 150.0
    Rd = 0.3
    TPU = 5.0
    g0 = 0.001
    g1 = 0.5
    vpd = e_sat(Ta) - vapor_pressure(Ta, Rh)
    PPFD = Rs*0.48*4.57

    constants = Constants()

        leaf = ModelList(
            energy_balance=Monteith(),
            photosynthesis=Fvcb(
                VcMaxRef=Vmax,
                JMaxRef=Jmax,
                RdRef=Rd,
                TPURef=TPU,
            ),
            stomatal_conductance=Medlyn(g0, g1),
            status=(
                Rₛ=Rs,
                sky_fraction=skyF,
                PPFD=PPFD,
                d=d,
            ),
        )
        deps = PlantSimEngine.dep(leaf)
        meteo = Atmosphere(T=Ta, Wind=Wind, P=P, Rh=Rh, Cₐ=Ca)
        st = PlantMeteo.row_struct(leaf.status[1])
        run!(leaf, deps, 1, st, meteo, constants, nothing) 
end

run_plantbiophysics()
=#