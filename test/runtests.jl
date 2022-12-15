using PlantSimEngine
using Test
using Tables, DataFrames

# Include the example dummy processes:
include("../examples/dummy.jl")

@testset "initialisations" begin
    include("test-initialisations.jl")
end

@testset "Status" begin
    include("test-Status.jl")
end

@testset "TimeStepTable" begin
    include("test-TimeStepTable.jl")
end

@testset "Dimensions" begin
    include("test-dimensions.jl")
end