# Pkg forwards --load to cache probes, dependency precompilers, and test runners.
# Defining a runtime module in Main is invalid while an incremental image is built.
if !Base.generating_output()
    include(joinpath(@__DIR__, "jet_analysis_guard_runtime.jl"))
end
