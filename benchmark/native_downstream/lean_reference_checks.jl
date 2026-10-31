module LeanNativeReferenceChecks

using Test, PlantSimEngine

const PSE = PlantSimEngine
const CR = Main.CompiledRegionsExperiment
const GP = CR.GP
const NG = Main.NativeGenericDriver
const Lean = Main.LeanNativeCompiler

export lean_reference_checks

"""
Bounded independent gate for direct compilation/typed execution without native
canonical columns. All mutable state and outputs belong to separate ordinary
reference-backed fixtures. No scientific equations are duplicated by this gate:
the established dense recurrence is the independent numerical oracle.
"""
function lean_reference_checks()
    reports = NamedTuple[]
    @testset "Lean direct compiler with ordinary reference ownership" begin
        for value_type in (:Float32, :Float64), outputs in (:none, :all)
            reference = NG.generic_native_fixture(; native=false, nobjects=3,
                nmodels=3, value_type)
            fixture = NG.generic_native_fixture(; native=false, nobjects=3,
                nmodels=3, value_type)
            control = PSE.run!(reference.model; steps=0, outputs)
            candidate = Lean.prepare_lean(fixture.model; steps=0, outputs,
                state_strategy=:references)
            @test candidate.model.status_storage === nothing
            @test isequal(CR.downstream_fingerprint(candidate), CR.downstream_fingerprint(control))
            canonical = PSE.model_status(fixture.model, 1)
            escaped = PSE.refvalue(canonical, GP._stage_name(1))
            @test escaped isa Base.RefValue
            echo = PSE.model_status(fixture.model, :echo)
            @test PSE.refvalue(echo, :supply) === PSE.refvalue(canonical, GP._stage_name(3))
            PSE.step!(candidate)
            PSE.step!(control)
            @test isequal(CR.downstream_fingerprint(candidate), CR.downstream_fingerprint(control))
            NG._check_generic_recurrence(candidate, fixture, 1)
            PSE.continue!(candidate; steps=2)
            PSE.continue!(control; steps=2)
            @test isequal(CR.downstream_fingerprint(candidate), CR.downstream_fingerprint(control))
            NG._check_generic_recurrence(candidate, fixture, 3)
            @test PSE.model_status(fixture.model, 1) === canonical
            @test PSE.refvalue(canonical, GP._stage_name(1)) === escaped
            report = Lean.lean_report(candidate)
            @test report.driver_row_executions > 0
            @test report.skipped_rich_targets > 0
            @test report.native_row_executions == 0
            @test report.executed_native_column_fields == 0
            @test report.lazy_target_snapshots == 0
            push!(reports, (; value_type, outputs,
                driver_row_executions=report.driver_row_executions,
                skipped_rich_targets=report.skipped_rich_targets,
                native_fields=report.executed_native_column_fields))
        end
    end
    return (; passed=true, cases=length(reports), reports,
        qualification=:ordinary_reference_ownership_direct_compiler_control,
        oracle=:original_executor_full_snapshot_and_independent_dense_recurrence)
end

end # module
