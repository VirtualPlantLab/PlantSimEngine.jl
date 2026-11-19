using Test
import CSV
using DataFrames
using Dates
include("oracle.jl")
using .OfficialXPalmOracle

# External verification only: invoke the fresh executable separately through
# the execution owner, with argument 1 and stdout redirected to this CSV file.
length(ARGS) == 1 || error("Expected the native T1 CSV path.")
@testset "Native real XPalm T1 against the independent official fixture" begin
    actual = CSV.read(only(ARGS), DataFrame; types=Dict(:date => Date))
    reference = OfficialXPalmOracle.official_t1()
    @test nrow(actual) == 1
    OfficialXPalmOracle.compare_daily(actual, reference)
end
