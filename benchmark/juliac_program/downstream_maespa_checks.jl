isdefined(@__MODULE__,:DownstreamMAESPAFixture) || include(joinpath(@__DIR__,"downstream_maespa_fixture.jl"))

module DownstreamMAESPAChecks

using Test
import ..DownstreamMAESPAFixture as Fixture
const PSE=Fixture.PSE

function _check_snapshot(actual,expected)
    @test keys(actual)==keys(expected)
    for component in keys(expected)
        @testset "$component" begin
            equal=isequal(getproperty(actual,component),getproperty(expected,component))
            # Avoid printing an entire scientific graph if a gate fails.
            @test equal
        end
    end
    return nothing
end
function _check_witness(value,config)
    @test value.scales[:Crown]==config.trees
    @test value.scales[:LogicalLeafUnit]==config.logical_leaf_slots
    @test value.active==value.accepted
    @test value.trials>=value.active
    @test value.soil_available
    @test abs(value.soil_residual)<1e-7
    for crown in value.crowns
        @test crown.mask_matches
        @test crown.aggregation_available
        @test crown.controller_available
        @test isfinite(crown.assimilation)
        @test isfinite(crown.temperature)
    end
    return nothing
end
function _check_positive_work(trace)
    @test maximum(value.active for value in trace)>0
    @test sum(value.trials for value in trace)>0
    @test sum(value.nonzero_assimilation for value in trace)>0
    return nothing
end

"""Fresh ordinary PSE A/A and continuation gates before any candidate timing."""
function check_ordinary(;config=Fixture.configuration(),per_step=config.steps<=4)
    before=Fixture.source_snapshot()
    left_fixture=Fixture.construct(config)
    right_fixture=Fixture.construct(config)
    left=Fixture.ordinary_start(left_fixture)
    right=Fixture.ordinary_start(right_fixture)
    trace=NamedTuple[]
    @testset "MAESPA complete ordinary A/A, $(config.copies) tiles × $(config.steps) steps" begin
        @test left_fixture.model!==right_fixture.model
        @test left_fixture.model.environment!==right_fixture.model.environment
        _check_snapshot(Fixture.ordinary_snapshot(right,right_fixture),Fixture.ordinary_snapshot(left,left_fixture))
        for step in 1:config.steps
            Fixture.ordinary_advance!(left)
            Fixture.ordinary_advance!(right)
            witness=Fixture.work_witness(left)
            _check_witness(witness,config)
            push!(trace,witness)
            if per_step || step==config.steps
                _check_snapshot(Fixture.ordinary_snapshot(right,right_fixture),Fixture.ordinary_snapshot(left,left_fixture))
            end
        end
        _check_positive_work(trace)
        uninterrupted_fixture=Fixture.construct(config)
        uninterrupted=Fixture.ordinary_start(uninterrupted_fixture)
        Fixture.ordinary_advance!(uninterrupted,config.steps)
        _check_snapshot(Fixture.ordinary_snapshot(uninterrupted,uninterrupted_fixture),Fixture.ordinary_snapshot(left,left_fixture))
        @test isequal(Fixture.source_snapshot(),before)
    end
    return (configuration=config,executor=:ordinary_PSE,trace,
        complete_state_history_rng_environment_and_continuation=true,
        source_sha256=before.aggregate_sha256)
end

"""
    check_candidate(candidate; config, per_step)

`candidate` must explicitly provide `kind=:full_compiled`, `prepare(fixture)`,
`advance(state, steps)`, `snapshot(state, fixture)` and `witness(state)`.
Snapshots and witnesses use the fixture's full ordinary schema. This is the
integration boundary for the registry-native backend; no ordinary execution or
kernel-only fallback is installed for the candidate. Its preparation must leave
the original CompositeModel's ordinary binding cache empty.
"""
function check_candidate(candidate;config=Fixture.configuration(),per_step=config.steps<=4)
    candidate.kind===:full_compiled || throw(ArgumentError("candidate must identify the complete compiled executor"))
    before=Fixture.source_snapshot()
    ordinary_fixture=Fixture.construct(config)
    compiled_fixture=Fixture.construct(config)
    ordinary=Fixture.ordinary_start(ordinary_fixture)
    compiled=candidate.prepare(compiled_fixture)
    trace=NamedTuple[]
    @testset "MAESPA full compiled/PSE parity, $(config.copies) tiles × $(config.steps) steps" begin
        @test isnothing(compiled_fixture.model.binding_cache)
        _check_snapshot(candidate.snapshot(compiled,compiled_fixture),Fixture.ordinary_snapshot(ordinary,ordinary_fixture))
        for step in 1:config.steps
            Fixture.ordinary_advance!(ordinary)
            candidate.advance(compiled,1)
            expected=Fixture.work_witness(ordinary)
            actual=candidate.witness(compiled)
            _check_witness(actual,config)
            same_work=isequal(actual,expected)
            @test same_work
            push!(trace,actual)
            if per_step || step==config.steps
                _check_snapshot(candidate.snapshot(compiled,compiled_fixture),Fixture.ordinary_snapshot(ordinary,ordinary_fixture))
            end
            @test isnothing(compiled_fixture.model.binding_cache)
        end
        _check_positive_work(trace)
        repeated_fixture=Fixture.construct(config)
        repeated=candidate.prepare(repeated_fixture)
        candidate.advance(repeated,config.steps)
        _check_snapshot(candidate.snapshot(repeated,repeated_fixture),candidate.snapshot(compiled,compiled_fixture))
        @test isequal(Fixture.source_snapshot(),before)
    end
    return (configuration=config,executor=:full_compiled,baseline=:ordinary_PSE,
        trace,complete_state_history_rng_environment_and_continuation=true,
        source_sha256=before.aggregate_sha256)
end

"""Positive daylight gate followed by full-day and population-width cases."""
function cases(;copies=(1,4),outputs_modes=(:none,:all))
    return [Fixture.configuration(;steps,start_slot,copies=population,outputs)
        for (steps,start_slot) in ((2,13),(24,13),(96,1))
        for population in copies for outputs in outputs_modes]
end

end
