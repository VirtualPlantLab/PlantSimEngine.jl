# For local testing :
#using Pkg
#Pkg.develop("PlantSimEngine")
#using PlantSimEngine

using Pkg
Pkg.add(url="https://github.com/VEZY/PlantBiophysics.jl#dev")
using Statistics
#using DataFrames
#using CSV
using Random
using PlantBiophysics
#using BenchmarkTools
#using Test
#using PlantMeteo

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
    #time_PB = Vector{Float64}(undef, N*microbenchmark_steps)
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
        #deps = PlantSimEngine.dep(leaf)
        meteo = Atmosphere(T=set.T[i], Wind=set.Wind[i], P=set.P[i], Rh=set.Rh[i], Cₐ=set.Ca[i])
        #st = PlantMeteo.row_struct(leaf.status[1])
        #b_PB = @benchmark run!($leaf, $meteo, $constants, nothing; executor = ThreadedEx()) evals = microbenchmark_evals samples = microbenchmark_steps
        run!(leaf, meteo, constants, nothing; executor = ThreadedEx())

        # transform in seconds        
        #=for j in 1:microbenchmark_steps
            time_PB[microbenchmark_steps*(i-1) + j] = b_PB.times[j]*1e-9
        end=#
    end
    #return time_PB
end

function setup_benchmark_plantbiophysics_multitimestep()

    Random.seed!(1) # Set random seed
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

    leaf = Vector{ModelList}(undef, N)
    for i = 1:N

        leaf[i] = ModelList(
            energy_balance=Monteith(),
            photosynthesis=Fvcb(
                VcMaxRef=set.VcMaxRef[i],
                JMaxRef=set.JMaxRef[i],
                RdRef=set.RdRef[i],
                TPURef=set.TPURef[i],
            ),
            stomatal_conductance=Medlyn(set.g0[i], set.g1[i]),
            status=(
                Rₛ=set.Rs,
                sky_fraction=set.sky_fraction,
                PPFD=set.PPFD,
                d=set.d,
            ),
        )
    end

    atm = Vector{Atmosphere}(undef, N)
    for i in 1:N
        atm[i]= Atmosphere(T=set.T[i], Wind=set.Wind[i], P=set.P[i], Rh=set.Rh[i], Cₐ=set.Ca[i])
    end
    meteo = Weather(atm)

    return leaf, meteo
end

function benchmark_plantbiophysics_multitimestep_MT(leaf, meteo)
    N = length(meteo)
    for i in 1:N
        run!(leaf[i], meteo, Constants(), nothing; executor = ThreadedEx())
    end
end

function benchmark_plantbiophysics_multitimestep_ST(leaf, meteo)
    N = length(meteo)
    for i in 1:N
        run!(leaf[i], meteo, Constants(), nothing; executor = SequentialEx())
    end
end