# Kaimon only. Loading definitions runs no simulation, profile, future catalogue
# or scientific kernel. Use the same loader for every factorial/cold arm.
isdefined(Main,:DirectPlannerMeasurements) && error("Use a fresh Julia image")
isdefined(Main,:NativePBDriver) || include(joinpath(@__DIR__,"load_experiments.jl"))
for (name,file) in (
    (:LeanNativeCompiler,"lean_compiler.jl"),
    (:DirectCallCompiler,"direct_calls.jl"),
    (:SharedCallProgram,"shared_call_program.jl"),
    (:TightCallProgram,"tight_call_program.jl"),
    (:BoundedPreparation,"bounded_preparation.jl"),
    (:PlannerBoundaries,"planner_boundaries.jl"),
    (:DirectPlanConstruction,"direct_plan_construction.jl"),
    (:DirectPlannerFixtures,"direct_planner_fixtures.jl"),
    (:DirectPlannerMeasurements,"direct_planner_measurements.jl"),
    (:DirectPlannerGrowthProfile,"direct_planner_growth_profile.jl"),
)
    isdefined(Main,name) || include(joinpath(@__DIR__,file))
end
