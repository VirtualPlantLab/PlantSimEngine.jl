# Kaimon-controlled definitions only. No scientific fixture is constructed.
isdefined(Main,:PersistentDownstreamMeasurements) && error("Use a fresh experiment image")
isdefined(Main,:DirectPlannerMeasurements) ||
    include(joinpath(@__DIR__,"load_newborn_binding_experiment.jl"))
for (name,file) in (
    (:GraphRowProjection,"graph_row_projection.jl"),
    (:TypedOutputPreparation,"typed_output_preparation.jl"),
    (:PersistentTightProgram,"persistent_tight_program.jl"),
    (:PersistentXPSourceAudit,"persistent_xp_source_audit.jl"),
    (:PersistentDownstreamMeasurements,"persistent_downstream_measurements.jl"),
    (:DirectCallCompilerChecks,"direct_calls_checks.jl"),
    (:PersistentTightChecks,"persistent_tight_checks.jl"),
    (:DirectPlanChecks,"direct_plan_checks.jl"),
    (:TightCallProgramChecks,"tight_call_program_checks.jl"),
    (:DirectManyChecks,"direct_many_checks.jl"),
    (:PersistentFeatureChecks,"persistent_feature_checks.jl"),
    (:PersistentTargetlessChecks,"persistent_targetless_checks.jl"),
)
    isdefined(Main,name) || include(joinpath(@__DIR__,file))
end
