"""
A sub-module with corner-cases intended to be used for tests, and a dependency graph generator to be used for some randomly seeded tests.
They may be of interest to modelers, or developers willing to tinker with PlantSimEngine.

"""
module InternalTests

using PlantSimEngine, MultiScaleTreeGraph, PlantMeteo, Statistics

outs = Dict(
    "E1" => ( :out1,:out),
    "E2" => (:out2,),)

#tupl = (1, 2, 3)
#tuple2 = (2, 4)
#outs = Dict{String, Tuple{Vararg{Symbol}}}("1" .=> tupl, "2" => tuple2)
#=outs_ = Dict{String, Vector{Symbol}}()
    for i in keys(outs)
        outs_[i] = [outs[i]...]
    end=#
    #outs_ = Dict{String, Vector{Symbol}}(i => Vector(outs[i]...) for i in keys(outs))
    outs_ = Dict(i => Vector(outs[i]...) for i in keys(outs))


# Processes:
export 

# Models:
export 



end