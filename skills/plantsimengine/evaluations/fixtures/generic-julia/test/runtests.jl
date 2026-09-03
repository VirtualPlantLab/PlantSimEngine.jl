using Test

include(joinpath(@__DIR__, "..", "src", "GenericJuliaFixture.jl"))
using .GenericJuliaFixture

@test stable_merge_sort([3, 1, 2, 1]) == [1, 1, 2, 3]
@test stable_merge_sort(Float32[2, -1, 0]) == Float32[-1, 0, 2]
