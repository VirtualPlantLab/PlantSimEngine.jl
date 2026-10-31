# Include only in a fresh Kaimon-controlled process for this checkout. Optional
# downstream packages use the existing local-path loader, not new dependencies.
isdefined(Main, :PreparationReuseMeasurements) && error(
    "Preparation experiment is already loaded; use a fresh Julia image")
include(joinpath(@__DIR__, "load_experiments.jl"))
for file in (
    "plan_view_reuse.jl", "bounded_preparation.jl",
    "plan_view_reuse_checks.jl", "bounded_preparation_checks.jl",
    "preparation_reuse_measurements.jl", "preparation_reuse_checks.jl",
)
    include(joinpath(@__DIR__, file))
end
