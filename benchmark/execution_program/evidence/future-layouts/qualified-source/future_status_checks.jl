module FutureStatusChecks

using Test, Random, PlantSimEngine
const PSE=PlantSimEngine
const Future=Main.FutureLayouts
const Fixtures=Main.FutureLayoutFixtures

export future_status_preparation_checks, future_status_alias_rejection_checks

_rng_draws(state)=rand(copy(state),UInt64,4)

"""Constructor-only pilot: no scientific kernel or sampler runs before growth.

This gate intentionally requests only status/layout constructors. The separate
future-call gate proves actual targetless scientific-entry type matches.
"""
function future_status_preparation_checks(;bounded=false)
    fixture=Fixtures.generic_future_fixture(;record_types=true)
    bounded && getfield(Main,:BoundedPreparation).enable_bounded_preparation!(fixture.model)
    simulation=PSE.run!(fixture.model;steps=0,outputs=:all)
    before=Fixtures.fixture_guard(fixture)
    before_snapshot=Fixtures.portable_snapshot(simulation)
    task_before=copy(Random.default_rng())
    task_seed_before=copy(Random.get_tls_seed())
    archetype=Future.FutureArchetype(:future_generic,fixture.future_builder;
        environment_types=fixture.environment_types)
    catalogue=Future.precompile_future_layouts!(simulation,archetype;
        bounded,outputs=:all,max_requests=4,status_max_requests=4,include_calls=false)
    # Julia Test resets the task RNG on entering each testset. Compare the
    # states captured around the operation, before that independent Test scope.
    task_after=copy(Random.default_rng())
    task_seed_after=copy(Random.get_tls_seed())
    report=Future.future_layout_report(catalogue)
    @testset "Future status constructors preserve live state and RNG before growth" begin
        @test Fixtures.fixture_guard(fixture)==before
        @test isequal(Fixtures.portable_snapshot(simulation),before_snapshot)
        @test _rng_draws(task_after)==_rng_draws(task_before)
        @test _rng_draws(task_seed_after)==_rng_draws(task_seed_before)
        @test before.kernel_calls==(creator=0,worker=0,child=0)
        @test before.samples==0
        @test Set(report.targetless_before)==Set((:worker,:child))
        @test report.status_layouts>0
        @test report.status_requests_attempted>0
        @test report.status_requests_accepted>0
        @test any(result -> result.label===:canonical_value_status_constructor &&
            result.accepted, catalogue.status_results)
        @test report.total_requests_attempted<=4
        @test report.retained_scientific_state===false
        @test report.scientific_kernels_executed===false
        @test report.sampled_for_signature_discovery===false
        @test PSE.current_step(simulation)==0
        PSE.step!(simulation)
        matches=Future.match_future_status_layouts(catalogue,simulation;
            object_ids=(PSE.ObjectId(1),))
        @test matches.observed>0
        @test matches.missed==0
        @test fixture.probe.creator_calls==1
        @test fixture.probe.worker_calls==1
        @test fixture.probe.child_calls==1
    end
    return (;passed=true,bounded,report,
        matches=Future.match_future_status_layouts(catalogue,simulation;object_ids=(1,)))
end

function future_status_alias_rejection_checks()
    fixture=Fixtures.generic_future_fixture()
    simulation=PSE.run!(fixture.model;steps=0,outputs=:none)
    before=Fixtures.fixture_guard(fixture)
    @testset "Future preparation rejects aliasing and restores task RNG on failure" begin
        rng_before=copy(Random.default_rng())
        seed_before=copy(Random.get_tls_seed())
        bad=Future.FutureArchetype(:bad,()->begin
            Random.seed!(97031)
            rand(Random.default_rng(),UInt64)
            fixture.model
        end;environment_types=fixture.environment_types)
        @test_throws ArgumentError Future.precompile_future_layouts!(simulation,bad;
            max_requests=0,status_max_requests=0,include_calls=false)
        @test Fixtures.fixture_guard(fixture)==before
        @test _rng_draws(copy(Random.default_rng()))==_rng_draws(rng_before)
        @test _rng_draws(copy(Random.get_tls_seed()))==_rng_draws(seed_before)
        @test PSE.current_step(simulation)==0
    end
    return (;passed=true)
end

end # module
