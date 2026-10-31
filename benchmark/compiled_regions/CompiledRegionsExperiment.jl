module CompiledRegionsExperiment

using Dates
using Statistics
using Test
using SHA
using PlantSimEngine

const PSE = PlantSimEngine

# Reuse the task's already loaded control module when present. A fresh Kaimon
# process can load this entry point on its own. No package source is modified.
if isdefined(Main, :GeneratedProgramExperiment)
    const GP = Main.GeneratedProgramExperiment
else
    include("../generated_program/GeneratedProgramExperiment.jl")
    const GP = GeneratedProgramExperiment
end

# The first-stage report loaded its extra feature fixtures explicitly. Make the
# second-stage entry point self-contained without modifying the frozen control.
if !isdefined(GP, :completion_optional_fixture)
    Base.include(GP, joinpath(@__DIR__, "../generated_program/feature_completion_checks.jl"))
end

include("state_storage.jl")
include("native_columns.jl")
include("resolved_calls.jl")
include("epoch_calls.jl")
include("inline_calls.jl")
include("region_backend.jl")
include("refresh_regions.jl")
include("reference_regions.jl")
include("append_reference_regions.jl")
include("region_trace.jl")
include("fixtures.jl")
include("checks.jl")
include("epoch_call_checks.jl")
include("call_interface_checks.jl")
include("call_exception_checks.jl")
include("inline_call_checks.jl")
include("call_distributed_checks.jl")
include("measurements.jl")
include("config_screen.jl")
include("native_screen.jl")

end
