module CompiledRegionsControls

using Dates
using Statistics
using Test
using PlantSimEngine

const PSE = PlantSimEngine
const GP = Main.GeneratedProgramExperiment

# This control module runs only the normal PSE executor. Author audits can be
# loaded before the experimental call compiler has been defined.
resolved_call_effects(::Type) = :ordered

include("fixtures.jl")

end
