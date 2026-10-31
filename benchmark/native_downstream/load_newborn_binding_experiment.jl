# Definitions only; use the same loader for all compared fresh scenarios.
isdefined(Main, :NewbornBindingMeasurements) && error("Use a fresh Julia image")
isdefined(Main, :DirectPlannerMeasurements) ||
    include(joinpath(@__DIR__, "load_direct_planner_experiment.jl"))
for (name, file) in (
    (:NewbornBindingProgram, "newborn_binding_program.jl"),
    (:NewbornBindingMeasurements, "newborn_binding_measurements.jl"),
)
    isdefined(Main, name) || include(joinpath(@__DIR__, file))
end
