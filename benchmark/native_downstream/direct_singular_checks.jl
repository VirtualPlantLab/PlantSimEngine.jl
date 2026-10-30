module DirectSingularRefreshChecks

using Test, PlantSimEngine
const PSE=PlantSimEngine
const Direct=Main.DirectCallCompiler
const Fixtures=Main.DirectCallCompilerChecks
const CR=Main.CompiledRegionsExperiment

export direct_singular_refresh_probe, direct_singular_refresh_checks

"""
Probe a saved One collection across an unrelated birth. The existing audited
controller records the saved target's time and executes it during its second
invocation, so wrapper metadata is part of scientific state and history.
Returns facts without assertions for before/after retirement-hook comparison.
"""
function direct_singular_refresh_probe(;native=true,inspect_before_growth=false,
    consume_refresh=false)
    left,right=(capture=Any[],),(capture=Any[],)
    reference=PSE.run!(Fixtures._retained_fixture(false);steps=0,outputs=:all,constants=left)
    candidate=Direct.prepare_direct_calls(Fixtures._retained_fixture(native);
        steps=0,outputs=:all,constants=right,state_strategy=native ? :native : :references)
    PSE.step!(reference)
    PSE.step!(candidate)
    initial_same=isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
    saved_reference,saved_candidate=only(left.capture),only(right.capture)
    if inspect_before_growth
        only(saved_reference)
        only(saved_candidate)
    end
    for simulation in (reference,candidate)
        PSE.register_object!(simulation.model,PSE.Object(:unrelated;status=(sentinel=1.0f0,)))
        if consume_refresh
            PSE.refresh_bindings!(simulation.model)
            PSE.refresh_environment_bindings!(simulation.model)
        end
    end
    PSE.step!(reference)
    PSE.step!(candidate)
    same_state_and_history=isequal(CR.downstream_fingerprint(candidate),
        CR.downstream_fingerprint(reference))
    left_target,right_target=only(saved_reference),only(saved_candidate)
    metadata(targets,target,simulation)=(container_time=targets.time,target_time=target.time,
        compiled_current=targets.compiled===PSE.compiled_bindings(simulation.model),
        environment_current=targets.environment_bindings===PSE.compiled_environment_bindings(simulation.model))
    reference_metadata=metadata(saved_reference,left_target,reference)
    candidate_metadata=metadata(saved_candidate,right_target,candidate)
    reference_captured_time=PSE.model_status(reference.model,:unit).captured_time
    candidate_captured_time=PSE.model_status(candidate.model,:unit).captured_time
    canonical_reference=PSE.refvalue(left_target.status,:value)===
        PSE.refvalue(PSE.model_status(reference.model,:unit),:value)
    canonical_candidate=PSE.refvalue(right_target.status,:value)===
        PSE.refvalue(PSE.model_status(candidate.model,:unit),:value)
    # A user may invoke the originally retained collection after the scheduler
    # refresh. Its publication time, status and history must match ordinary PSE.
    PSE.run_call!(left_target;sampled_environment=5.0,publish=true)
    PSE.run_call!(right_target;sampled_environment=5.0,publish=true)
    external_call_same=isequal(CR.downstream_fingerprint(candidate),
        CR.downstream_fingerprint(reference))
    return (;native,inspect_before_growth,consume_refresh,initial_same,
        same_state_and_history,reference_metadata,candidate_metadata,
        reference_captured_time,candidate_captured_time,
        canonical_reference,canonical_candidate,external_call_same,
        retained_identity=only(left.capture)===saved_reference && only(right.capture)===saved_candidate,
        report=Direct.direct_call_report(candidate))
end

function direct_singular_refresh_checks()
    reports=Any[]
    @testset "Retained One keeps ordinary metadata and publication across unrelated birth" begin
        for native in (false,true), inspect_before_growth in (false,true), consume_refresh in (false,true)
            result=direct_singular_refresh_probe(;native,inspect_before_growth,consume_refresh)
            @test result.initial_same
            @test result.same_state_and_history
            @test result.reference_metadata==result.candidate_metadata
            @test result.reference_captured_time==result.candidate_captured_time==2.0
            @test result.canonical_reference && result.canonical_candidate
            @test result.external_call_same
            @test result.retained_identity
            @test result.report.executed_numerical_roots==1
            @test result.report.executed_numerical_calls==1
            push!(reports,result)
        end
    end
    return (;passed=true,reports)
end

end
