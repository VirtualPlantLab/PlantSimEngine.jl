using PlantSimEngine
using Test
using Tables, DataFrames

@testset "initialisations" begin
    include("test-initialisations.jl")
end

@testset "Status" begin
    include("test-Status.jl")
end

@testset "TimeStepTable" begin
    include("test-TimeStepTable.jl")
end