# Definitions only. Use the same loader for every fresh-process comparison.
isdefined(Main, :GrowthInputMeasurements) && error("Use a fresh Julia image")
isdefined(Main, :DirectPlannerMeasurements) ||
    include(joinpath(@__DIR__, "load_direct_planner_experiment.jl"))
for (name, file) in (
    (:GrowthInputReuse, "growth_input_reuse.jl"),
    (:GrowthPlanStorage, "growth_plan_storage.jl"),
    (:GrowthInputMeasurements, "growth_input_measurements.jl"),
    (:GrowthInputProfile, "growth_input_profile.jl"),
)
    isdefined(Main, name) || include(joinpath(@__DIR__, file))
end
