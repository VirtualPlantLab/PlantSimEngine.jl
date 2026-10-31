module LocalPortsSelectedBridgeChecks

using Test, PlantSimEngine
const PSE = PlantSimEngine
const Bridge = Main.LocalPortsSelectedBridge
const Measurements = Main.DirectPlannerMeasurements
const CR = Main.CompiledRegionsExperiment
const Native = Main.NativePBDriver

export local_ports_xp_checks, registration_rejection_checks

"""Reuse the independent exact two-day XP oracle, then require actual new work."""
Base.@nospecializeinfer @noinline function local_ports_xp_checks(; steps=2,
    arm::Symbol=:selected_driver)
    registration = Bridge.local_ports_registration_report()
    registration.registered_types == 4 || error("Register the four audited XP types before this check")
    # This existing oracle constructs independent models/RNGs/forcing and
    # compares each step's complete state/types/history/topology, scientific
    # RNG fingerprints, and canonical reference identity transitions.
    result = Base.invokelatest(Measurements.direct_planner_checks, :xp;
        arm, steps, outputs=:all)
    driver = result.reports[:coverage].driver
    @testset "Optional local-port admission executes original XP kernels before growth" begin
        @test driver.selected_batches_prepared > 0
        @test driver.batch_executions > 0
        @test driver.executed_numerical_roots > 0
        @test driver.executed_numerical_calls == 0
        @test driver.live_selected_batches == 0
        @test driver.fallback_programs_materialized > 0
        @test driver.shared_frames_materialized > 0
        @test !isempty(result.reports[:work].added_ids)
    end
    return (; passed=true, registration, driver, oracle=result,
        qualification=:separate_changed_admission_not_original_zero_eligibility_cohort)
end

PSE.@process "local_bridge_typed_context_probe" verbose=false
PSE.@process "local_bridge_explicit_probe" verbose=false
struct TypedContextProbe <: AbstractLocal_Bridge_Typed_Context_ProbeModel end
struct ExplicitCapabilityProbe <: AbstractLocal_Bridge_Explicit_ProbeModel end
PSE.inputs_(::TypedContextProbe) = (;)
PSE.outputs_(::TypedContextProbe) = (value=0.0,)
PSE.inputs_(::ExplicitCapabilityProbe) = (;)
PSE.outputs_(::ExplicitCapabilityProbe) = (value=0.0,)
PSE.run!(::TypedContextProbe, status, environment, constants, context::PSE.RunContext) = nothing
PSE.run!(::ExplicitCapabilityProbe, status, environment, constants, context) = nothing
CR.region_effects(::Type{TypedContextProbe}) = :local_ports
CR.region_effects(::Type{ExplicitCapabilityProbe}) = :local_ports
Native.native_call_effects(::Type{ExplicitCapabilityProbe}) = :ordered

function registration_rejection_checks()
    explicit_before = which(Native.native_call_effects, Tuple{Type{ExplicitCapabilityProbe}})
    report = Base.invokelatest(Bridge.register_local_ports_models!,
        (TypedContextProbe(), ExplicitCapabilityProbe()))
    @testset "Local-port bridge preserves explicit capabilities and context dispatch" begin
        @test all(row -> row.status === :rejected, report.rows)
        @test first(report.rows).reason in (:no_generic_context_method, :private_context_dispatch_not_proven)
        @test last(report.rows).reason === :explicit_capability_preserved
        @test which(Native.native_call_effects, Tuple{Type{ExplicitCapabilityProbe}}) === explicit_before
        @test Native.native_call_effects(ExplicitCapabilityProbe) === :ordered
        @test report.scientific_methods_changed === false
    end
    return (; passed=true, report)
end

end # module
