#using Pkg
#Pkg.develop("PlantSimEngine")
#using PlantSimEngine

# no release of XPalm yet, so can't just add it to the .toml
using Pkg
Pkg.add(url="https://github.com/PalmStudio/XPalm.jl")

using Test
using PlantMeteo#, MultiScaleTreeGraph
#using CairoMakie, AlgebraOfGraphics
using DataFrames, CSV, Statistics
using Dates
using XPalm
using BenchmarkTools

function xpalm_default_param_run()
    meteo = CSV.read("../XPalm.jl/0-data/Meteo_Nigeria_PR.txt", DataFrame)
    meteo.duration = [Dates.Day(i[1:1]) for i in meteo.duration]
    m = Weather(meteo)

    out_vars = Dict{String,Any}(
        "Scene" => (:lai,),
        # "Scene" => (:lai, :scene_leaf_area, :aPPFD, :TEff),
        # "Plant" => (:plant_age, :ftsw, :newPhytomerEmergence, :aPPFD, :plant_leaf_area, :carbon_assimilation, :carbon_offer_after_rm, :Rm, :TT_since_init, :TEff, :phytomer_count, :newPhytomerEmergence),
        "Leaf" => (:Rm, :potential_area, :TT_since_init, :TEff, :A, :carbon_demand, :carbon_allocation,),
        # "Leaf" => (:Rm, :potential_area),
        # "Internode" => (:Rm, :carbon_allocation, :carbon_demand),
        "Male" => (:Rm,),
        # "Female" => (:biomass,),
        # "Soil" => (:TEff, :ftsw, :root_depth),
    )

    # Example 1: Run the model with the default parameters (but output as a DataFrame):
    #df = xpalm(m; vars=out_vars, sink=DataFrame)
    df = XPalm.xpalm(m, DataFrame; vars=out_vars)
end

#=@testset "XPalm simple test" begin
    # default number of seconds is 5
    b_XP = @benchmark xpalm_default_param_run() seconds = 120
    
    #N = length(b_XP.times)

    @test mean(b_XP.times*1e-9) > 10
    @test mean(b_XP.times*1e-9) < 15
end =#