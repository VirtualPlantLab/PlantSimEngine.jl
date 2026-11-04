# Include through Kaimon. The optional executable is an already-built bundle.
isdefined(Main, :FullXPalmNativeChecks) || include(joinpath(@__DIR__, "full_xpalm_native_checks.jl"))
isdefined(Main, :MixedCadenceFixture) || include(joinpath(@__DIR__, "app", "src", "mixed_cadence_fixture.jl"))

module MixedCadenceChecks

using Dates
using Test
using PlantSimEngine
import ..MixedCadenceFixture as Fixture
import ..FullXPalmNativeChecks as NativeChecks

const PSE = PlantSimEngine
const PLANT = ObjectId(2)
const CHUNKS = (24, 26)

function _ordinary_samples(simulation)
    return Dict((row.application_id, ObjectId(row.object_id).value, row.timestep, row.variable) => row.value
        for row in PSE.collect_outputs(simulation; sink=nothing))
end

function _prepared_samples(state)
    return Dict((sample.application, sample.object_id, sample.step, variable) => sample.value
        for app in state.applications for (variable, history) in pairs(app.streams)
        for sample in history.retained)
end

function _compare(state, simulation)
    cohort, row = state.locations[PLANT.value]
    status = NamedTuple(state.cohorts[cohort].rows[row])
    ordinary = PSE.final_state(simulation, PLANT)
    @test all(name -> isequal(status[name], ordinary[name]), keys(status))
    @test _prepared_samples(state) == _ordinary_samples(simulation)
    return status
end

function _test_schedule(clock, due)
    program = Fixture.prepare(; readout_every=clock)
    @test program.base_step_seconds == 3600
    ordinary = PSE.run!(Fixture.scene(; readout_every=clock); steps=0, outputs=:all)
    state = Fixture.instantiate(program)
    for chunk in CHUNKS
        PSE.continue!(ordinary; steps=chunk)
        Fixture.advance!(state, chunk)
        _compare(state, ordinary)
    end
    expected = _ordinary_samples(ordinary)
    @test [step for step in 1:50 if haskey(expected, (:readout, 2, step, :current))] == due
    @test all(step -> expected[(:hourly, 2, step, :hourly_total)] == step, 1:50)
    for (count, step) in enumerate(due)
        @test expected[(:readout, 2, step, :current)] == step
        @test expected[(:readout, 2, step, :previous)] == step - 1
        @test expected[(:tick, 2, step, :ticks)] == count
    end
    return ordinary, state
end

function _test_native(executable, ordinary, state)
    function run_cadence(hours...)
        command = Cmd([abspath(executable), "cadence", string.(hours)...])
        command = addenv(command, "JULIA_PROJECT"=>nothing, "JULIA_LOAD_PATH"=>nothing)
        return NativeChecks.parse_native(read(command, String))
    end
    result = run_cadence(state.step)
    @test run_cadence(CHUNKS...) == result
    @test (result.objects, result.step, result.applications) == (2, state.step, 3)
    @test result.topology == Dict(1=>(:Scene, 0, :/, 1), 2=>(:Plant, 1, :+, 1))
    @test isempty(result.rng)
    expected = _ordinary_samples(ordinary)
    @test Dict(key => parse(Int, value) for (key, value) in result.samples) == expected
    canonical = PSE.final_state(ordinary, PLANT)
    cohort, row = state.locations[PLANT.value]
    @test Dict(key => parse(Int, value) for (key, value) in result.states) ==
        Dict((:Plant, 2, name) => canonical[name] for name in keys(state.cohorts[cohort].rows[row]))
    return nothing
end

function run_checks(; executable=nothing)
    return @testset "Canonical mixed cadences" begin
        @testset "hourly and daily applications" begin
            ordinary, state = _test_schedule(Day(1), [1, 25, 49])
            isnothing(executable) || _test_native(executable, ordinary, state)
        end
        @testset "phased integer and generic clocks" begin
            _test_schedule(ClockSpec(6.0, 3.0), collect(3:6:50))
            _test_schedule(ClockSpec(2.5, 0.5), collect(3:5:50))
        end
    end
end

end
