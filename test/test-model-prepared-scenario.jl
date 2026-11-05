using Dates
using PlantSimEngine
using PlantSimEngine.GraphEditor: GlobalApplicationRef, SetModelInputBinding, UpdateModelApplication, apply_model_graph_edit
using Random: Xoshiro
using Test

PlantSimEngine.@process "prepared_scenario_producer" verbose = false
struct PreparedScenarioProducer <: AbstractPrepared_Scenario_ProducerModel
    rng::Xoshiro
end

PlantSimEngine.inputs_(::PreparedScenarioProducer) = NamedTuple()
PlantSimEngine.outputs_(::PreparedScenarioProducer) = (signal=0.0,)

function PlantSimEngine.run!(model::PreparedScenarioProducer, status, environment, constants, context)
    status.signal += rand(model.rng)
    return nothing
end

PlantSimEngine.@process "prepared_scenario_reader" verbose = false
struct PreparedScenarioReader <: AbstractPrepared_Scenario_ReaderModel end

PlantSimEngine.inputs_(::PreparedScenarioReader) = (lagged=Required(Float64),)
PlantSimEngine.outputs_(::PreparedScenarioReader) = (observed=0.0,)

function PlantSimEngine.run!(::PreparedScenarioReader, status, environment, constants, context)
    status.observed = status.lagged
    return nothing
end

function prepared_scenario_fixture(;
    duration=Hour(1), cadence=Hour(2), seed=29, sensor_parent=:plant_a,
    reader_scope=SelfPlant(),
)
    reader(name, plant, source_scope) = ModelSpec(
        PreparedScenarioReader(); name,
        on=Many(scale=:Sensor, within=Scope(plant)),
        inputs=(PreviousTimeStep(:lagged) => One(
            scale=:Source, within=source_scope, application=:producer, var=:signal,
        ),),
    )
    return CompositeModel(
        Object(:plant_a; scale=:Plant),
        Object(:plant_b; scale=:Plant),
        Object(:source_a; scale=:Source, parent=:plant_a, status=Status(signal=1.0)),
        Object(:source_b; scale=:Source, parent=:plant_b, status=Status(signal=10.0)),
        Object(:sensor; scale=:Sensor, parent=sensor_parent, status=Status(lagged=-1.0));
        applications=(
            ModelSpec(PreparedScenarioProducer(Xoshiro(seed));
                name=:producer, on=Many(scale=:Source), every=cadence),
            reader(:reader_a, :plant_a, reader_scope),
            reader(:reader_b, :plant_b, SelfPlant()),
        ),
        environment=(; duration),
    )
end

function test_prepared_scenario_parity(left, right)
    @test current_step(left) == current_step(right)
    for id in (:source_a, :source_b, :sensor)
        @test final_state(left, id) == final_state(right, id)
    end
    @test Dict(key => collect(stream) for (key, stream) in outputs(left)) ==
          Dict(key => collect(stream) for (key, stream) in outputs(right))
end

@testset "Prepared scenario is reused with independent runtime state" begin
    model = prepared_scenario_fixture()
    initial_status = model_object(model, :sensor).status
    prepared = PlantSimEngine._prepare_scenario_plan(model)
    @test PlantSimEngine._prepare_scenario_plan(model) === prepared
    @test isnothing(Advanced.compiled_bindings(model))
    @test model_object(model, :sensor).status === initial_status

    # A lowering may assemble target vectors, but those vectors belong to that execution.
    left_apps = PlantSimEngine._scenario_applications(prepared)
    empty!(only(app for app in left_apps if app.id == :reader_a).target_ids)
    right_apps = PlantSimEngine._scenario_applications(prepared)
    @test only(app for app in right_apps if app.id == :reader_a).target_ids == [ObjectId(:sensor)]

    copied_model = deepcopy(model)
    copied = PlantSimEngine._prepare_scenario_plan(copied_model)
    fresh_model = prepared_scenario_fixture()
    first_fresh = PlantSimEngine._prepare_scenario_plan(fresh_model)
    fresh = PlantSimEngine._prepare_scenario_plan(fresh_model; force=true)
    @test fresh !== first_fresh

    cached_sim = run!(model; steps=2, outputs=:all)
    @test cached_sim.compiled.scenario_plan === prepared.plan
    continue!(cached_sim; steps=4)
    fresh_sim = run!(fresh_model; steps=6, outputs=:all)
    copied_sim = run!(copied_model; steps=6, outputs=:all)
    @test fresh_sim.compiled.scenario_plan === fresh.plan
    @test copied_sim.compiled.scenario_plan === copied.plan
    test_prepared_scenario_parity(cached_sim, fresh_sim)
    test_prepared_scenario_parity(copied_sim, fresh_sim)
    signal_key = (:producer, ObjectId(:source_a), :signal)
    @test outputs(cached_sim)[signal_key] !== outputs(copied_sim)[signal_key]
end

@testset "Prepared scenario follows object membership changes" begin
    model = prepared_scenario_fixture()
    first = PlantSimEngine._prepare_scenario_plan(model)
    register_object!(model, Object(:extra; scale=:Sensor, parent=:plant_b, status=Status(lagged=-1.0)))
    added = PlantSimEngine._prepare_scenario_plan(model)
    @test added !== first
    @test only(app for app in PlantSimEngine._scenario_applications(added) if app.id == :reader_b).target_ids ==
          [ObjectId(:extra)]

    reparent_object!(model, :sensor, :plant_b)
    moved = PlantSimEngine._prepare_scenario_plan(model)
    @test moved !== added
    @test isempty(only(app for app in PlantSimEngine._scenario_applications(moved) if app.id == :reader_a).target_ids)

    remove_object!(model, :extra)
    removed = PlantSimEngine._prepare_scenario_plan(model)
    @test removed !== moved
    @test only(app for app in PlantSimEngine._scenario_applications(removed) if app.id == :reader_b).target_ids ==
          [ObjectId(:sensor)]

    cached_sim = run!(model; steps=4, outputs=:all)
    fresh_model = prepared_scenario_fixture(; sensor_parent=:plant_b)
    fresh_sim = run!(fresh_model; steps=4, outputs=:all)
    @test cached_sim.compiled.scenario_plan === removed.plan
    @test PlantSimEngine._prepare_scenario_plan(fresh_model).plan === fresh_sim.compiled.scenario_plan
    test_prepared_scenario_parity(cached_sim, fresh_sim)

    # A live simulation still handles additions through its incremental refresh.
    register_object!(model, Object(:new_sensor; scale=:Sensor, parent=:plant_a, status=Status(lagged=-1.0)))
    pending = PlantSimEngine._prepare_scenario_plan(model)
    @test only(app for app in PlantSimEngine._scenario_applications(pending) if app.id == :reader_a).target_ids ==
          [ObjectId(:new_sensor)]
    continue!(cached_sim; steps=1)
    @test cached_sim.compiled.scenario_plan === removed.plan
    @test cached_sim.compiled.applications_by_id.reader_a.target_ids == [ObjectId(:new_sensor)]
    @test PlantSimEngine._prepare_scenario_plan(model).plan === cached_sim.compiled.scenario_plan
    @test haskey(outputs(cached_sim), (:reader_a, ObjectId(:new_sensor), :observed))
end

@testset "Prepared scenario follows clock and application changes" begin
    model = prepared_scenario_fixture()
    first = PlantSimEngine._prepare_scenario_plan(model)
    run!(model; steps=0)
    model.environment = (duration=Hour(2),)
    mark_environment_binding_dirty!(model)
    cached_sim = run!(model; steps=4, outputs=:all)
    new_clock = PlantSimEngine._prepare_scenario_plan(model)
    @test cached_sim.compiled.scenario_plan === new_clock.plan
    @test first.plan.timeline.base_step_seconds == 3600.0
    @test new_clock.plan.timeline.base_step_seconds == 7200.0
    fresh_sim = run!(prepared_scenario_fixture(; duration=Hour(2)); steps=4, outputs=:all)
    test_prepared_scenario_parity(cached_sim, fresh_sim)

    continued_model = prepared_scenario_fixture()
    ongoing = run!(continued_model; steps=0, outputs=:all)
    continued_model.environment = (duration=Hour(2),)
    mark_environment_binding_dirty!(continued_model)
    step!(ongoing)
    @test !Advanced.environment_bindings_dirty(continued_model)
    @test ongoing.compiled.scenario_plan.timeline.base_step_seconds == 3600.0
    restarted = run!(continued_model; steps=0)
    @test restarted.compiled.scenario_plan.timeline.base_step_seconds == 7200.0
    @test restarted.compiled.scenario_plan.applications_by_id.producer.clock.dt == 1.0
    @test ongoing.compiled.scenario_plan.timeline.base_step_seconds == 3600.0

    authored = prepared_scenario_fixture()
    original = PlantSimEngine._prepare_scenario_plan(authored)
    edited = apply_model_graph_edit(authored, UpdateModelApplication(
        GlobalApplicationRef(:producer), PreparedScenarioProducer(Xoshiro(37)),
        :producer, Many(scale=:Source), Hour(3),
    ))
    edited = apply_model_graph_edit(edited, SetModelInputBinding(
        GlobalApplicationRef(:reader_a), :lagged,
        One(scale=:Source, within=Scope(:plant_b), application=:producer,
            var=:signal, policy=PreviousTimeStep(:lagged)),
    ))
    changed = PlantSimEngine._prepare_scenario_plan(edited)
    @test PlantSimEngine._prepare_scenario_plan(authored) === original
    @test original.plan.applications_by_id.producer.clock.dt == 2.0
    @test changed.plan.applications_by_id.producer.clock.dt == 3.0
    edited_sim = run!(edited; steps=6, outputs=:all)
    fresh = prepared_scenario_fixture(; cadence=Hour(3), seed=37, reader_scope=Scope(:plant_b))
    @test edited_sim.compiled.scenario_plan === changed.plan
    test_prepared_scenario_parity(edited_sim, run!(fresh; steps=6, outputs=:all))
end
