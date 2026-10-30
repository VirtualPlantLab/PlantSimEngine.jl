# Its source is a property-only scalar kernel plus refvalue capture. The
# captured canonical cell, rather than the temporary row object, escapes.
direct_status_compatible(::Type{NativeReferenceEscape}) = true

"""Checked direct rows preserve real PB state/history and canonical public state."""
function pb_direct_status_checks(; nobjects::Int=4, steps::Int=2)
    reference = PSE.run!(CR.pb_many_fixture(; nobjects, steps); steps=0, outputs=:all)
    fixture = pb_native_fixture(; nobjects, steps)
    simulation = PSE.run!(fixture.model; steps=0, outputs=:all)
    program = compile_native_call_driver(simulation; status_strategy=:direct)
    @testset "Checked direct-column PB rows preserve full scientific state" begin
        PSE.continue!(reference; steps)
        advance_native_call_driver!(program; steps)
        @test isequal(CR.downstream_fingerprint(simulation), CR.downstream_fingerprint(reference))
        report = native_call_driver_report(program)
        @test report.executed_direct_roots == nobjects * steps
        @test report.executed_direct_calls == report.executed_numerical_calls > 0
        @test report.executed_direct_fields == report.executed_native_column_fields > 0
        @test report.fallback_calls == 0

        canonical = PSE.model_status(fixture.model, 1)
        row = NativeDirectStatus(_native_status_view(canonical))
        @test PSE.refvalue(row, :Ra_SW_f) === PSE.refvalue(canonical, :Ra_SW_f)
        @test PSE._status_identity(row) === PSE._status_identity(canonical)
        @test keys(row) == keys(canonical)
        @test propertynames(row) == propertynames(canonical)
        @test NamedTuple(row) == NamedTuple(canonical)
        @test Tuple(row) == Tuple(canonical)
        @test collect(row) == collect(canonical)
        @test row == canonical
        @test canonical == row

        # An unaudited direct representation always retains ordinary Status.
        @test _native_kernel_status(getfield(row, :view), CR.GateCallWorker(), Val(:direct)) isa PSE.Status
    end

    # Real accesses remain checked even if an outsider invalidates a backing
    # vector. This intentionally corrupted fixture is never advanced again.
    invalid = pb_native_fixture(; nobjects=1, steps=1)
    PSE.run!(invalid.model; steps=0, outputs=:none)
    canonical = PSE.model_status(invalid.model, 1)
    row = NativeDirectStatus(_native_status_view(canonical))
    source = getfield(PSE.refvalue(canonical, :Ra_SW_f), :x)
    @testset "Direct status preserves outside-vector bounds checks" begin
        resize!(source, 0)
        @test_throws BoundsError row.Ra_SW_f
        @test_throws BoundsError setproperty!(row, :Ra_SW_f, 7.0)
        @test_throws BoundsError canonical.Ra_SW_f
    end
    return (; passed=true, report=native_call_driver_report(program),
        compared=:all_final_states_and_raw_histories, bounds=:checked,
        scientific_kernels=:original_unmodified_methods)
end

"""A direct numerical kernel can lend the unchanged canonical RefArray cell."""
function direct_kernel_reference_escape_checks()
    model = PSE.CompositeModel(PSE.Object(:escaper; status=(value=0.0, visits=0));
        applications=(PSE.ModelSpec(NativeReferenceEscape(); name=:escape,
            on=PSE.One(id=:escaper), every=Hour(1)),),
        environment=(duration=Hour(1),), status_storage=PSE.NativeColumnStorage())
    captured = Any[]
    simulation = PSE.run!(model; constants=(capture=captured,), steps=0, outputs=:all)
    program = compile_native_call_driver(simulation; status_strategy=:direct)
    @testset "Direct numerical kernel lends the exact canonical escaped reference" begin
        advance_native_call_driver!(program; steps=1)
        canonical = PSE.model_status(model, :escaper)
        @test only(captured) === PSE.refvalue(canonical, :value)
        only(captured)[] = 9.0
        @test canonical.value == 9.0
        PSE.continue!(simulation; steps=1)
        @test first(captured)[] == 10.0
        advance_native_call_driver!(program; steps=1)
        @test first(captured)[] == 11.0
        report = native_call_driver_report(program)
        @test report.executed_direct_roots == 2
        @test report.executed_direct_fields > 0
    end
    return (; passed=true, report=native_call_driver_report(program))
end
