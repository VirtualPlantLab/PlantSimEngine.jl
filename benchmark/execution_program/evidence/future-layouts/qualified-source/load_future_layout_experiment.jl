# Run through Kaimon only. Generic qualification deliberately avoids importing
# downstream scientific packages. Load the existing downstream loader separately
# before optional PB/XP fixture cases. Loading this file runs no simulations.
using PlantSimEngine
isdefined(Main,:BoundedPreparation) || include(joinpath(@__DIR__,"bounded_preparation.jl"))
for file in ("future_call_layouts.jl","future_layouts.jl","future_layout_fixtures.jl",
    "future_layout_measurements.jl","future_layout_checks.jl")
    include(joinpath(@__DIR__,file))
end
