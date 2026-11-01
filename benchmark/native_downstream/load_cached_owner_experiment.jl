# Definitions only. Start a project-specific Kaimon session before loading.
# No scenario, scientific kernel or proof cache is prepared by this loader.
isdefined(Main,:CachedOwnerMeasurements) && error("Use a fresh experiment image")
isdefined(Main,:PersistentDownstreamMeasurements) ||
    include(joinpath(@__DIR__,"load_persistent_experiment.jl"))
for (name,file) in (
    (:CachedDeclarationProofs,"cached_declaration_proofs.jl"),
    (:CachedDeclarationProofChecks,"cached_declaration_proofs_checks.jl"),
    (:ColdOwnerProgram,"cold_owner_program.jl"),
    (:CachedOwnerMeasurements,"cached_owner_measurements.jl"),
    (:CachedOwnerChecks,"cached_owner_checks.jl"),
    (:CachedOwnerIdentityChecks,"cached_owner_identity_checks.jl"),
)
    isdefined(Main,name) || include(joinpath(@__DIR__,file))
end
