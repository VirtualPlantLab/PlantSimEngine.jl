module PublicScheduleForceChecks

using Dates, PlantSimEngine, Test
const PSE = PlantSimEngine
PSE.@process "public_schedule_force" verbose=false

struct Tick{T} <: AbstractPublic_Schedule_ForceModel
    trace::T
end
PSE.inputs_(::Tick) = NamedTuple()
PSE.outputs_(::Tick) = (ticks=0,)
function PSE.run!(model::Tick, status, environment, constants, context)
    push!(model.trace, Int(context.time))
    status.ticks += 1
    return nothing
end

@testset "public configuration refresh adopts the current cadence within its prepared schema" begin
    for (old_cadence, new_cadence, expected) in (
        (2, 4, [1, 5]),
        (4, 2, [1, 3, 5, 7]),
        (3, 5, [1, 6]),
    )
        @testset "cadence $old_cadence to $new_cadence" begin
            trace = Int[]
            spec = ModelSpec(Tick(trace); name=:tick, on=One(id=:scene),
                every=Hour(old_cadence))
            model = CompositeModel(Object(:scene; scale=:Scene);
                applications=(spec,),
                environment=[(duration=Hour(1), T=20.0) for _ in 1:7])
            simulation = run!(model; steps=1, outputs=:all)
            @test trace == [1]
            original_cell = PSE.refvalue(model_status(model, :scene), :ticks)
            previous_type = typeof(simulation.compiled)
            model.applications[1] = PSE._replace_model_spec(model.applications[1];
                every=Hour(new_cadence))
            current = Advanced.refresh_bindings!(model; force=true)
            @test typeof(current) === previous_type
            @test PSE.refvalue(model_status(model, :scene), :ticks) === original_cell
            continue!(simulation; steps=6)
            @test trace == expected
            @test model_status(model, :scene).ticks == length(expected)
            @test collect(outputs(simulation)[(:tick, ObjectId(:scene), :ticks)]) ==
                  [(Float64(time), value) for (value, time) in enumerate(expected)]
        end
    end
end

@testset "a changed schedule schema requires a fresh simulation" begin
    for (old_cadence, new_cadence, expected) in ((1, 3, [1, 4, 7]), (3, 1, collect(1:7)))
        trace = Int[]
        model = CompositeModel(Object(:scene; scale=:Scene);
            applications=(ModelSpec(Tick(trace); name=:tick, on=One(id=:scene),
                every=Hour(old_cadence)),),
            environment=[(duration=Hour(1), T=20.0) for _ in 1:7])
        simulation = run!(model; steps=1, outputs=:all)
        original_cell = PSE.refvalue(model_status(model, :scene), :ticks)
        previous_type = typeof(simulation.compiled)
        model.applications[1] = PSE._replace_model_spec(model.applications[1];
            every=Hour(new_cadence))
        current = Advanced.refresh_bindings!(model; force=true)
        @test typeof(current) !== previous_type
        @test_throws ArgumentError step!(simulation)
        @test trace == [1]
        fresh = run!(model; steps=7, outputs=:all)
        @test trace == [1; expected]
        @test PSE.refvalue(model_status(model, :scene), :ticks) === original_cell
        @test model_status(model, :scene).ticks == 1 + length(expected)
        @test collect(outputs(fresh)[(:tick, ObjectId(:scene), :ticks)]) ==
              [(Float64(time), value + 1) for (value, time) in enumerate(expected)]
    end
end

@testset "growth shares the definition and copied timelines own their heaps" begin
    trace = Int[]
    model = CompositeModel(Object(:scene; scale=:Scene);
        applications=(ModelSpec(Tick(trace); name=:tick, on=One(id=:scene), every=Hour(2)),),
        environment=[(duration=Hour(1), T=20.0) for _ in 1:7])
    simulation = run!(model; steps=1, outputs=:all)
    schedule = simulation.execution_plan.schedule
    definition = simulation.compiled.scenario_plan.application_schedule
    @test schedule.definition === definition
    register_object!(model, Object(:unused; scale=:Other))
    step!(simulation)
    @test simulation.execution_plan.schedule === schedule
    @test simulation.compiled.scenario_plan.application_schedule === definition
    @test schedule.definition === definition
    @test trace == [1]

    copied = deepcopy(simulation)
    @test copied.execution_plan.schedule !== schedule
    @test copied.execution_plan.schedule.heap !== schedule.heap
    @test copied.execution_plan.schedule.definition ===
          copied.compiled.scenario_plan.application_schedule
    @test copied.execution_plan.schedule.definition !== definition
    step!(copied)
    @test model_status(copied.model, :scene).ticks == 2
    @test model_status(model, :scene).ticks == 1
    @test schedule.last_step == 2
    @test copied.execution_plan.schedule.last_step == 3
end

PSE.@process "schedule_force_midstep" verbose=false
struct ChangeCadence <: AbstractSchedule_Force_MidstepModel end
PSE.inputs_(::ChangeCadence) = NamedTuple()
PSE.outputs_(::ChangeCadence) = (forced=false,)
function PSE.run!(::ChangeCadence, status, environment, constants, context)
    if context.time == 3.0 && !status.forced
        model = runtime_model(context)
        model.applications[2] = PSE._replace_model_spec(model.applications[2]; every=Hour(5))
        Advanced.refresh_bindings!(model; force=true)
        status.forced = true
    end
    return nothing
end

@testset "a mid-step force preserves applications already due and replans following steps" begin
    trace = Int[]
    model = CompositeModel(Object(:scene; scale=:Scene);
        applications=(
            ModelSpec(ChangeCadence(); name=:change_tick, on=One(id=:scene)),
            ModelSpec(Tick(trace); name=:tick, on=One(id=:scene), every=Hour(2)),
        ), environment=[(duration=Hour(1), T=20.0) for _ in 1:8])
    simulation = run!(model; steps=8, outputs=:all)
    @test model_status(model, :scene).forced
    @test trace == [1, 3, 6]
    @test model_status(model, :scene).ticks == 3
    @test collect(outputs(simulation)[(:tick, ObjectId(:scene), :ticks)]) ==
          [(1.0, 1), (3.0, 2), (6.0, 3)]
    @test simulation.execution_plan.schedule.definition ===
          simulation.compiled.scenario_plan.application_schedule
    @test simulation.execution_plan.schedule.last_step == current_step(simulation) == 8
end

end
