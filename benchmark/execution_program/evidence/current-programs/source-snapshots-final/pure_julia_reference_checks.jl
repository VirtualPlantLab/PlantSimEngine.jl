module PureJuliaReferenceChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine
const Pure = Main.PureJuliaReference
const PBDriver = Main.NativePBDriver
const CR = Main.CompiledRegionsExperiment

export pure_pb_checks

function _check_all_fields(reference, plain)
    @test Set(keys(reference)) == Set(keys(plain))
    for name in keys(reference)
        @test isequal(getproperty(reference, name), getproperty(plain, name))
        @test typeof(getproperty(reference, name)) === typeof(getproperty(plain, name))
    end
end

"""
    pure_pb_checks(; nobjects=2, steps=2, include_direct=true)

Cheap exact scientific equivalence and work-count gate for the fixed PB
numerical lower bound. Compare every input/default/output field and its type,
every step, using independent cells and original scientific model methods.
This does not qualify missing framework services as equivalent features.
"""
function pure_pb_checks(; nobjects::Int=2, steps::Int=2, include_direct::Bool=true)
    reference_fixture = PBDriver.pb_native_fixture(; native=false, nobjects, steps)
    reference = PSE.run!(reference_fixture.model; steps=0, outputs=:none)
    fixture = Pure.plain_pb_fixture(; nobjects, steps)
    counted = Pure.prepare_pure_pb(fixture; count_calls=true)
    plain = Pure.prepare_pure_pb(fixture; count_calls=false)
    direct_backend = include_direct ? getfield(Main, :DirectCallCompiler) : nothing
    direct = include_direct ? direct_backend.prepare_direct_calls(
        PBDriver.pb_native_fixture(; native=false, nobjects, steps).model;
        steps=0, outputs=:none, state_strategy=:references, status_strategy=:direct) : nothing
    expected_photosynthesis = 0
    @testset "Pure Julia reference executes the original complete PB numerical task" begin
        @test plain.counts === nothing
        @test counted.counts !== nothing
        @test isequal(Pure.pure_pb_snapshot(plain), CR.portable_downstream_snapshot(reference))
        @test isequal(Pure.pure_pb_snapshot(counted), CR.portable_downstream_snapshot(reference))
        for index in 1:nobjects
            oracle = PSE.final_state(reference, index)
            _check_all_fields(oracle, plain.rows[index])
            for name in keys(oracle)
                plain_ref = getfield(getfield(plain.rows[index], :cells), name)
                counted_ref = getfield(getfield(counted.rows[index], :cells), name)
                @test plain_ref isa Base.RefValue
                @test plain_ref !== counted_ref
                @test plain_ref !== PSE.refvalue(PSE.model_status(reference.model, index), name)
            end
        end
        for step in 1:steps
            # Verify the scientific forcing values and precision independently
            # of state parity, without timing or using this schema in Pure.
            batch = first(reference.execution_plan.batches)
            target = first(batch.targets)
            sampled = PSE._model_environment_for_binding(reference.environment_bindings,
                batch.application, target.environment_binding, Float64(step),
                PSE._NO_ENVIRONMENT_OVERRIDE)
            raw = fixture.weather[step]
            for name in keys(PSE.environment_inputs_(fixture.models.energy))
                @test isequal(getproperty(raw, name), getproperty(sampled, name))
                @test typeof(getproperty(raw, name)) === typeof(getproperty(sampled, name))
            end
            PSE.step!(reference)
            Pure.advance_pure_pb!(counted; steps=1)
            Pure.advance_pure_pb!(plain; steps=1)
            include_direct && PSE.step!(direct)
            for index in 1:nobjects
                oracle = PSE.final_state(reference, index)
                _check_all_fields(oracle, plain.rows[index])
                _check_all_fields(oracle, counted.rows[index])
                # Original Monteith increments iter only after a non-converged
                # iteration. On exhaustion it equals maxiter, otherwise the
                # converged iteration adds one photosynthesis/stomata pair.
                expected_photosynthesis += min(fixture.models.energy.maxiter, oracle.iter + 1)
            end
            expected = CR.portable_downstream_snapshot(reference)
            @test isequal(Pure.pure_pb_snapshot(plain), expected)
            @test isequal(Pure.pure_pb_snapshot(counted), expected)
            include_direct && (@test isequal(CR.portable_downstream_snapshot(direct), expected))
            actual = Pure.pure_pb_report(counted).work
            @test actual.roots == nobjects * step
            @test actual.photosynthesis == expected_photosynthesis
            @test actual.stomata == expected_photosynthesis
            @test actual.model_lookups == expected_photosynthesis
            if include_direct
                report = direct_backend.direct_call_report(direct)
                @test report.executed_numerical_roots == actual.roots
                @test report.executed_numerical_calls == actual.photosynthesis + actual.stomata
                @test report.typed_model_lookups == actual.model_lookups
                @test iszero(report.fallback_calls)
            end
        end
        # The lower bound explicitly refuses the PSE services it omits.
        context = Pure.PlainPBContext(plain.models, first(plain.rows), plain.constants, plain.counts)
        snapshot = Pure.pure_pb_snapshot(plain)
        @test_throws ArgumentError PSE.run_call!(context, :photosynthesis;
            sampled_environment=fixture.weather[1], publish=true)
        @test isequal(Pure.pure_pb_snapshot(plain), snapshot)
    end
    return (passed=true, nobjects, steps, fields_per_object=length(keys(first(plain.rows))),
        counted_work=Pure.pure_pb_report(counted).work,
        uncounted_report=Pure.pure_pb_report(plain),
        qualification=:exact_all_scientific_fields_types_forcing_and_original_iterative_work,
        omitted_features_are_not_claimed=true)
end

end # module
