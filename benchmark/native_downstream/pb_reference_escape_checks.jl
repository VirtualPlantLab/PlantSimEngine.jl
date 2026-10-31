# A scientific reference can escape a kernel without a context escaping. The
# fixed-call capability permits this; the fresh numerical row must still lend
# the canonical live cell instead of a copy of its current value.
PSE.@process "native_reference_escape" verbose=false
struct NativeReferenceEscape <: AbstractNative_Reference_EscapeModel end
PSE.inputs_(::NativeReferenceEscape) = (;)
PSE.outputs_(::NativeReferenceEscape) = (value=0.0, visits=0)
function PSE.run!(::NativeReferenceEscape, status, environment, constants, context)
    status.value += 1.0
    status.visits += 1
    push!(constants.capture, PSE.refvalue(status, :value))
    return nothing
end
native_call_effects(::Type{NativeReferenceEscape}) = :fixed_native_calls

function native_kernel_reference_escape_checks()
    function fixture(native)
        objects = (PSE.Object(:escaper; status=(value=0.0, visits=0)),)
        applications = (PSE.ModelSpec(NativeReferenceEscape(); name=:escape,
            on=PSE.One(id=:escaper), every=Hour(1)),)
        native ? PSE.CompositeModel(objects...; applications,
            environment=(duration=Hour(1),), status_storage=PSE.NativeColumnStorage()) :
            PSE.CompositeModel(objects...; applications, environment=(duration=Hour(1),))
    end
    plain_constants, native_constants = (capture=Any[],), (capture=Any[],)
    reference = PSE.run!(fixture(false); constants=plain_constants, steps=0, outputs=:all)
    simulation = PSE.run!(fixture(true); constants=native_constants, steps=0, outputs=:all)
    program = compile_native_call_driver(simulation)
    @testset "Native kernel escaping reference remains canonical and live" begin
        PSE.continue!(reference; steps=1)
        advance_native_call_driver!(program; steps=1)
        @test isequal(CR.downstream_fingerprint(simulation), CR.downstream_fingerprint(reference))
        escaped = only(native_constants.capture)
        @test escaped isa Base.RefArray
        status = PSE.model_status(PSE.runtime_model(simulation), :escaper)
        canonical = PSE.refvalue(status, :value)
        @test getfield(escaped, :x) === getfield(canonical, :x)
        @test getfield(escaped, :i) == getfield(canonical, :i)
        escaped[] = 9.0
        only(plain_constants.capture)[] = 9.0
        @test status.value == 9.0
        PSE.continue!(reference; steps=1)
        PSE.continue!(simulation; steps=1)
        @test escaped[] == 10.0
        @test isequal(CR.downstream_fingerprint(simulation), CR.downstream_fingerprint(reference))
        PSE.continue!(reference; steps=1)
        advance_native_call_driver!(program; steps=1)
        @test escaped[] == 11.0
        @test isequal(CR.downstream_fingerprint(simulation), CR.downstream_fingerprint(reference))
        @test native_call_driver_report(program).executed_numerical_roots == 2
        @test native_call_driver_report(program).executed_native_column_fields > 0
    end
    return (; passed=true, report=native_call_driver_report(program))
end
