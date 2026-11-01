module XPPreparationScalingChecks

using Test, PlantSimEngine
const PSE=PlantSimEngine
const S=Main.XPPreparationScaling
const F=Main.DirectPlannerFixtures
const D=Main.XPDispatchRefreshMeasurements
const CR=Main.CompiledRegionsExperiment
export xp_scaling_fixture_checks, xp_preparation_scaling_checks, xp_scaling_config_checks

function xp_scaling_config_checks()
    @testset "Single-scene scaling dimensions and explicit opt-in" begin
        for profile in (:accelerated,:package_defaults),days in (2,12,32)
            config=S.xp_scaling_config(;days,profile)
            @test config.scene_count==config.palm_count==1
            @test config.scaling_axis===:duration_and_realized_organs_in_one_original_scene
        end
        @test_throws ArgumentError S.xp_scaling_config(;days=64)
        @test_throws ArgumentError S.xp_scaling_config(;days=128)
        @test S.xp_scaling_config(;days=64,allow_large=true).days==64
        @test_throws ArgumentError S.xp_scaling_config(;days=0)
        @test_throws ArgumentError S.xp_scaling_config(;profile=:unknown)
        @test_throws ArgumentError S._arms((:ordinary_a,:ordinary_a))
        @test_throws ArgumentError S._arms((:unknown,))
        @test S._dispatch_arm(:typed_only)===:typed_barrier
    end
    return (;passed=true,scientific_execution=false)
end

"""New accelerated builder matches the frozen original fixture, every step."""
Base.@nospecializeinfer @noinline function xp_scaling_fixture_checks(;days::Int=2)
    config=S.xp_scaling_config(;days,profile=:accelerated,outputs=:all)
    weather=CR._xpalm_fixture_weather(days)
    left=Base.invokelatest(Main.NativeXPDriver.xpalm_native_fixture;
        native=false,steps=days,seed=config.seed,emission_speed=0.2,weather)
    right=Base.invokelatest(S.construct_xp_scaling_fixture,config;weather)
    reference=Base.invokelatest(S.prepare_xp_scaling,left,:ordinary_a;outputs=:all)
    candidate=Base.invokelatest(S.prepare_xp_scaling,right.model,:ordinary_a;outputs=:all)
    @testset "Exact original accelerated XP fixture" begin
        @test right.parameter_provenance.phyllochron_effective==(initial=0.2,mature=0.2)
        @test right.scene_count==right.palm_count==1
        @test right.model!==left
        @test right.model.environment!==left.environment
        @test isequal(S.xp_scaling_observation(reference),S.xp_scaling_observation(candidate))
        old_left,old_right=F.identities(left),F.identities(right.model)
        @test all(key->old_left.references[key]!==old_right.references[key],keys(old_left.references))
        for _ in 1:days
            Base.invokelatest(PSE.step!,reference);Base.invokelatest(PSE.step!,candidate)
            @test isequal(S.xp_scaling_observation(reference),S.xp_scaling_observation(candidate))
            next_left,next_right=F.identities(left),F.identities(right.model)
            @test D._same_status_shapes(next_left,next_right)
            @test F.same_identity_transitions(old_left,old_right,next_left,next_right)
            old_left,old_right=next_left,next_right
        end
        return (;passed=true,days,oracle=:frozen_accelerated_fixture,
            work=S.xp_scaling_work(candidate,right,config))
    end
end

"""Independent full trajectories; diagnostics are intentionally outside timing.

Compare exact complete states/raw histories, numeric/status/carrier types, RNG,
reference lifecycle and actual work after every original daily step. Defaults
may produce no newborns, and receive no newborn credit when this happens.
"""
Base.@nospecializeinfer @noinline function xp_preparation_scaling_checks(;
    days::Int=2,profile::Symbol=:accelerated,arms=S.XP_SCALING_ARMS,
    allow_large::Bool=false,live_binding_checks::Bool=true)
    requested=S._arms(arms)
    :ordinary_a in requested || throw(ArgumentError("Include ordinary_a oracle"))
    names=(:ordinary_a,Tuple(arm for arm in requested if arm!==:ordinary_a)...)
    config=S.xp_scaling_config(;days,profile,outputs=:all,allow_large)
    weather=CR._xpalm_fixture_weather(days)
    fixtures=Dict{Symbol,Any}();simulations=Dict{Symbol,Any}();identities=Dict{Symbol,Any}()
    evidence=Dict{Symbol,Any}()
    @testset "Single-scene $profile XP trajectory: $days days" begin
        for arm in names
            fixture=Base.invokelatest(S.construct_xp_scaling_fixture,config;weather)
            fixtures[arm]=fixture
            simulations[arm]=Base.invokelatest(S.prepare_xp_scaling,fixture.model,arm;outputs=:all)
            identities[arm]=Base.invokelatest(F.identities,fixture.model)
            @test fixture.scene_count==fixture.palm_count==1
            @test fixture.initial_object_count==length(fixture.initial_ids)
            @test fixture.parameter_provenance.parameter_changes===
                (profile===:accelerated ? (:production_speed_initial,:production_speed_mature) : ())
            if profile===:package_defaults
                @test fixture.parameter_provenance.phyllochron_before==
                    fixture.parameter_provenance.phyllochron_effective
            end
            @test isequal(Base.invokelatest(S.xp_scaling_observation,simulations[arm]),
                Base.invokelatest(S.xp_scaling_observation,simulations[:ordinary_a]))
        end
        for arm in names
            arm===:ordinary_a && continue
            @test fixtures[arm].model!==fixtures[:ordinary_a].model
            @test D._same_status_shapes(identities[:ordinary_a],identities[arm])
            @test all(key->identities[:ordinary_a].references[key]!==identities[arm].references[key],
                keys(identities[:ordinary_a].references))
        end
        for _ in 1:days
            old=copy(identities)
            for arm in names
                Base.invokelatest(PSE.step!,simulations[arm])
                identities[arm]=Base.invokelatest(F.identities,fixtures[arm].model)
                if live_binding_checks
                    Base.invokelatest(Main.GrowthInputReuseChecks._live_bindings,simulations[arm])
                end
            end
            expected=Base.invokelatest(S.xp_scaling_observation,simulations[:ordinary_a])
            expected_work=Base.invokelatest(CR.downstream_work_report,simulations[:ordinary_a],
                fixtures[:ordinary_a].initial_ids)
            for arm in names
                @test isequal(Base.invokelatest(S.xp_scaling_observation,simulations[arm]),expected)
                @test D._same_status_shapes(identities[:ordinary_a],identities[arm])
                @test F.same_identity_transitions(old[:ordinary_a],old[arm],
                    identities[:ordinary_a],identities[arm])
                @test Base.invokelatest(CR.downstream_work_report,simulations[arm],fixtures[arm].initial_ids)==expected_work
            end
        end
        for arm in names
            evidence[arm]=Base.invokelatest(S.xp_scaling_coverage,simulations[arm],fixtures[arm],config,arm)
            @test evidence[arm].trajectory_arm===arm
            @test evidence[arm].scene_count==evidence[arm].palm_count==1
        end
        return (;passed=true,days,profile,arms=names,evidence,
            work=Base.invokelatest(S.xp_scaling_work,simulations[:ordinary_a],fixtures[:ordinary_a],config),
            oracle=:ordinary_exact_every_step_state_raw_history_rng_types_refs_carriers_and_work,
            single_scene=true,independent_replicas_per_sample=1)
    end
end

end # module
