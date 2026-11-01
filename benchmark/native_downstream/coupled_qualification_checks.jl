module CoupledQualificationChecks

using Test, PlantSimEngine
const PSE=PlantSimEngine
const Q=Main.CoupledQualification
export coupled_checks,coupled_continuation_checks,coupled_snapshot_contract_checks

"""The shared qualification runner owns policy enablement; this only injects it.

`prepare(fixture,config,arm)` must start a fresh zero-step ordinary simulation.
Run tiny one/two-interval gates before a four-interval positive-physiology case.
"""
function coupled_checks(prepare;config=Q.config(),
    arms=(:ordinary_b,:graph_only,:prep_candidate),require_positive=false)
    evidence=Any[]
    @testset "Coupled AMAPSim ArchimedLight PlantBiophysics exact preservation" begin
        for arm in arms
            left=Base.invokelatest(Q.construct,config)
            right=Base.invokelatest(Q.construct,config)
            reference=Base.invokelatest(prepare,left,config,:ordinary_a)
            candidate=Base.invokelatest(prepare,right,config,arm)
            @test PSE.current_step(reference)==PSE.current_step(candidate)==0
            @test isequal(Q.fingerprint(reference,left,config),Q.fingerprint(candidate,right,config))
            old_left,old_right=Q.identities(left.model),Q.identities(right.model)
            @test old_left.alias_signature==old_right.alias_signature
            @test all(key->old_left.statuses[key]!==old_right.statuses[key],keys(old_left.statuses))
            @test all(key->old_left.references[key]!==old_right.references[key],keys(old_left.references))
            phases=Any[]
            for step in 1:config.steps
                Base.invokelatest(PSE.step!,reference)
                Base.invokelatest(PSE.step!,candidate)
                @test PSE.current_step(reference)==PSE.current_step(candidate)==step
                @test isequal(Q.fingerprint(reference,left,config),Q.fingerprint(candidate,right,config))
                new_left,new_right=Q.identities(left.model),Q.identities(right.model)
                @test Q.same_identity_transitions(old_left,old_right,new_left,new_right)
                old_left,old_right=new_left,new_right
                expected,actual=Q.work(reference,left,config),Q.work(candidate,right,config)
                @test isequal(actual,expected)
                Q.check(reference,left,config;require_positive=require_positive && step==config.steps)
                Q.check(candidate,right,config;require_positive=require_positive && step==config.steps)
                push!(phases,(;step,work=actual,
                    clocks=Q.nested_clocks(candidate,right,config)))
            end
            push!(evidence,(;arm,phases,exact_state_topology_geometry_rng_history=true,
                exact_status_reference_types_aliases_and_identity_transitions=true))
        end
    end
    return (;passed=true,config,require_positive,evidence,benchmark_claim=false,
        clock_exclusions=Q.EXCLUDED_CLOCK_OUTPUTS,
        ownership_normalization=:qualified_native_plant_objectid_to_checked_logical_identity,
        scope=:original_coupled_scientific_models_with_ordinary_execution)
end

"""One continue! call and a split step!/continue! reach the same exact timeline."""
function coupled_continuation_checks(prepare;config=Q.config(;steps=2),
    arm=:prep_candidate,require_positive=false)
    config.steps>=2 || throw(ArgumentError("Continuation gate requires at least two intervals"))
    left,right=Base.invokelatest(Q.construct,config),Base.invokelatest(Q.construct,config)
    reference=Base.invokelatest(prepare,left,config,:ordinary_a)
    candidate=Base.invokelatest(prepare,right,config,arm)
    @testset "Coupled continuation retains ordinary state and publications" begin
        Base.invokelatest(PSE.continue!,reference;steps=config.steps)
        Base.invokelatest(PSE.step!,candidate)
        Base.invokelatest(PSE.continue!,candidate;steps=config.steps-1)
        @test PSE.current_step(reference)==PSE.current_step(candidate)==config.steps
        @test isequal(Q.fingerprint(reference,left,config),Q.fingerprint(candidate,right,config))
        @test isequal(Q.work(reference,left,config),Q.work(candidate,right,config))
        Q.check(reference,left,config;require_positive)
        Q.check(candidate,right,config;require_positive)
    end
    return (;passed=true,config,arm,require_positive,
        work=Q.work(candidate,right,config),benchmark_claim=false)
end

"""Check exclusions against real scientific state, including deliberate negatives.

Only a disposable ordinary scene is modified. Explicit timer perturbations are
ignored, whereas physical duration, native physical time, RNG state, ownership
validity and realized geometry must each change the scientific fingerprint.
"""
function coupled_snapshot_contract_checks(prepare;config=Q.config(;steps=2))
    fixture=Base.invokelatest(Q.construct,config)
    simulation=Base.invokelatest(prepare,fixture,config,:ordinary_a)
    Base.invokelatest(PSE.step!,simulation)
    state=Q.Adapter.native_state(fixture.model,fixture.plant.id)
    scene=Q._scene_object(fixture.model).status
    base=Q.fingerprint(simulation,fixture,config)
    @testset "Coupled fingerprint excludes timers but retains physical state" begin
        scene.geometry_seconds+=7.25
        scene.light_seconds+=9.5
        @test isequal(Q.fingerprint(simulation,fixture,config),base)
        duration=scene.preceding_interval_seconds
        scene.preceding_interval_seconds+=1.0
        @test !isequal(Q.fingerprint(simulation,fixture,config),base)
        scene.preceding_interval_seconds=duration
        time=state.development.physical_time
        state.development.physical_time+=1.0
        @test !isequal(Q.fingerprint(simulation,fixture,config),base)
        state.development.physical_time=time
        draws=state.native.plant.rng.draws
        state.native.plant.rng.draws+=1
        @test !isequal(Q.fingerprint(simulation,fixture,config),base)
        state.native.plant.rng.draws=draws
        identity=state.development.plant_identity
        state.development.plant_identity=identity ⊻ UInt(1)
        @test !isequal(Q.fingerprint(simulation,fixture,config),base)
        state.development.plant_identity=identity
        @test isequal(Q.fingerprint(simulation,fixture,config),base)
        if !isempty(state.native.plant.organs)
            organ=first(state.native.plant.organs)
            length=organ.length
            organ.length+=0.5f0
            @test !isequal(Q.fingerprint(simulation,fixture,config),base)
            organ.length=length
            @test isequal(Q.fingerprint(simulation,fixture,config),base)
        end
    end
    return (;passed=true,clock_exclusions=Q.EXCLUDED_CLOCK_OUTPUTS,
        physical_duration_rng_identity_and_geometry_are_retained=true,
        geometry_perturbation_exercised=!isempty(state.native.plant.organs),
        benchmark_claim=false)
end

end # module
