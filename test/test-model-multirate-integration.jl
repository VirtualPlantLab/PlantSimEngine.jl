using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "hourly_leaf_flux" verbose = false
PlantSimEngine.@process "daily_plant_flux" verbose = false
PlantSimEngine.@process "daily_soil_state" verbose = false

struct HourlyLeafFluxModel <: AbstractHourly_Leaf_FluxModel end
struct DailyPlantFluxModel <: AbstractDaily_Plant_FluxModel end
struct DailySoilStateModel <: AbstractDaily_Soil_StateModel end
PlantSimEngine.inputs_(::HourlyLeafFluxModel) = (rate=Required(Float64),)
PlantSimEngine.outputs_(::HourlyLeafFluxModel) = (flux=0.0, hourly_runs=0)
function PlantSimEngine.run!(::HourlyLeafFluxModel, status, environment, constants, context)
    status.flux = status.rate
    status.hourly_runs += 1
end
PlantSimEngine.inputs_(::DailyPlantFluxModel) = (leaf_fluxes=Required(Vector{Float64}),)
PlantSimEngine.outputs_(::DailyPlantFluxModel) = (daily_total=0.0, daily_runs=0)
function PlantSimEngine.run!(::DailyPlantFluxModel, status, environment, constants, context)
    status.daily_total = sum(status.leaf_fluxes)
    status.daily_runs += 1
end
PlantSimEngine.inputs_(::DailySoilStateModel) = NamedTuple()
PlantSimEngine.outputs_(::DailySoilStateModel) = (soil_runs=0,)
function PlantSimEngine.run!(::DailySoilStateModel, status, environment, constants, context)
    status.soil_runs += 1
end

PlantSimEngine.@process "event_schedule_probe" verbose = false
PlantSimEngine.@process "event_schedule_growth" verbose = false
PlantSimEngine.@process "generic_event_schedule_probe" verbose = false

struct EventScheduleProbeModel <: AbstractEvent_Schedule_ProbeModel
    application_id::Symbol
    log::Vector{Tuple{Int,Symbol}}
end

struct EventScheduleGrowthModel <: AbstractEvent_Schedule_GrowthModel
    leaf_id::Symbol
end

struct GenericEventScheduleProbeModel <:
       AbstractGeneric_Event_Schedule_ProbeModel end

PlantSimEngine.inputs_(::EventScheduleProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::EventScheduleProbeModel) = (runs=0,)
function PlantSimEngine.run!(
    model::EventScheduleProbeModel,
    status,
    environment,
    constants,
    context,
)
    status.runs += 1
    push!(model.log, (Int(context.time), model.application_id))
    return nothing
end

PlantSimEngine.inputs_(::EventScheduleGrowthModel) = NamedTuple()
PlantSimEngine.outputs_(::EventScheduleGrowthModel) = (created=0,)
function PlantSimEngine.run!(
    model::EventScheduleGrowthModel,
    status,
    environment,
    constants,
    context,
)
    runtime = runtime_model(context)
    ObjectId(model.leaf_id) in object_ids(runtime) && return nothing
    register_object!(
        runtime,
        Object(
            model.leaf_id;
            scale=:Leaf,
            parent=:scene,
            status=Status(runs=0),
        ),
    )
    status.created += 1
    return nothing
end

PlantSimEngine.inputs_(::GenericEventScheduleProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::GenericEventScheduleProbeModel) = (runs=0,)
PlantSimEngine.timespec(::Type{<:GenericEventScheduleProbeModel}) =
    ClockSpec(2.5, 0.5)
function PlantSimEngine.run!(
    ::GenericEventScheduleProbeModel,
    status,
    environment,
    constants,
    context,
)
    status.runs += 1
    return nothing
end

PlantSimEngine.@process "temporal_retention_source" verbose = false
PlantSimEngine.@process "temporal_retention_probe" verbose = false
struct TemporalRetentionSourceModel <: AbstractTemporal_Retention_SourceModel end
struct TemporalRetentionProbeModel <: AbstractTemporal_Retention_ProbeModel
    history::Vector{Float64}
end
PlantSimEngine.inputs_(::TemporalRetentionSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::TemporalRetentionSourceModel) = (signal=0.0,)
function PlantSimEngine.run!(::TemporalRetentionSourceModel, status, environment, constants, context)
    status.signal += 1.0
    return nothing
end
PlantSimEngine.inputs_(::TemporalRetentionProbeModel) =
    (current=Required(Float64), sample=Required(Float64))
PlantSimEngine.outputs_(::TemporalRetentionProbeModel) = (observed=0.0,)
function PlantSimEngine.run!(model::TemporalRetentionProbeModel, status, environment, constants, context)
    status.observed = status.sample
    push!(model.history, status.observed)
    return nothing
end

@testset "sparse clocks preserve preceding publications with bounded retention" begin
    for policy in (PreviousTimeStep(:sample), Interpolate())
        previous = policy isa PreviousTimeStep
        histories = Vector{Float64}[]
        for retention in (:none, :all)
            history = Float64[]
            temporal_input = previous ?
                policy => One(scale=:Cell, application=:source, var=:signal) :
                :sample => One(scale=:Cell, application=:source, var=:signal, policy=policy)
            model = CompositeModel(Object(:cell; scale=:Cell, status=Status(sample=0.0)); applications=(
                ModelSpec(
                    TemporalRetentionSourceModel(); name=:source, on=One(scale=:Cell),
                    every=ClockSpec(2.5, previous ? 0.5 : 1.0),
                ),
                ModelSpec(
                    TemporalRetentionProbeModel(history); name=:probe, on=One(scale=:Cell),
                    inputs=(
                        :current => One(scale=:Cell, application=:source, var=:signal),
                        temporal_input,
                    ),
                ),
            ))
            simulation = run!(model; steps=8, outputs=retention)
            continue!(simulation; steps=10)
            push!(histories, history)
            if retention === :none
                stream = outputs(simulation)[(:source, ObjectId(:cell), :signal)]
                @test stream isa PlantSimEngine.TemporalDependencyBuffer
                @test length(stream) == 2
                @test length(stream.times) == 4
            end
        end
        expected = previous ?
            Float64[count(sample_time -> sample_time < time, 3:5:18) for time in 1:18] :
            [time < 6 ? 1.0 : 1.0 + (time - 1) / 5 for time in 1:18]
        @test histories[1] ≈ expected
        @test histories[2] ≈ expected
    end
end

@testset "new consumers expand wrapped temporal buffers without replacing them" begin
    totals = Float64[]
    for retention in (:none, :all)
        short_history, long_history = Float64[], Float64[]
        consumer_spec(name, scale, window, history) = ModelSpec(
            TemporalRetentionProbeModel(history); name=name, on=Many(scale=scale),
            inputs=(
                :current => One(scale=:Source, within=SceneScope(), application=:source, var=:signal),
                :sample => One(
                    scale=:Source, within=SceneScope(), application=:source, var=:signal,
                    policy=Integrate(), window=window,
                ),
            ),
        )
        model = CompositeModel(
            Object(:source; scale=:Source), Object(:short; scale=:Short);
            applications=(
                ModelSpec(TemporalRetentionSourceModel(); name=:source, on=One(scale=:Source)),
                consumer_spec(:short, :Short, 2.0, short_history),
                consumer_spec(:long, :Long, 5.0, long_history),
            ),
        )
        simulation = run!(model; steps=5, outputs=retention)
        key = (:source, ObjectId(:source), :signal)
        stream = outputs(simulation)[key]
        if retention === :none
            @test stream.first_slot != 1
            @test collect(stream) == [(4.0, 4.0), (5.0, 5.0)]
        end
        register_object!(model, Object(:long; scale=:Long))
        continue!(simulation; steps=0)
        @test outputs(simulation)[key] === stream
        if retention === :none
            @test length(stream.times) == 5
            @test collect(stream) == [(4.0, 4.0), (5.0, 5.0)]
        end
        continue!(simulation; steps=5)
        @test last(short_history) == 19.0
        @test last(long_history) == 40.0
        push!(totals, final_state(simulation, :long).observed)
        if retention === :none
            @test collect(stream) == [(Float64(time), Float64(time)) for time in 6:10]
            @test length(stream.times) == 5
        end
    end
    @test totals == [40.0, 40.0]
end

@testset "48-hour hourly/daily stack and plant isolation" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:soil; scale=:Soil, parent=:scene),
        Object(:plant_1; scale=:Plant, parent=:scene),
        Object(:plant_1_leaf_1; scale=:Leaf, parent=:plant_1, status=Status(rate=1.0)),
        Object(:plant_1_leaf_2; scale=:Leaf, parent=:plant_1, status=Status(rate=2.0)),
        Object(:plant_2; scale=:Plant, parent=:scene),
        Object(:plant_2_leaf_1; scale=:Leaf, parent=:plant_2, status=Status(rate=10.0)),
        Object(:plant_2_leaf_2; scale=:Leaf, parent=:plant_2, status=Status(rate=20.0));
        applications=(
            ModelSpec(HourlyLeafFluxModel(); name=:hourly_flux, on=Many(scale=:Leaf), every=Hour(1)),
            ModelSpec(DailyPlantFluxModel(); name=:daily_plant, on=Many(scale=:Plant), inputs=(:leaf_fluxes => Many(
                    scale=:Leaf,
                    within=Subtree(),
                    application=:hourly_flux,
                    var=:flux,
                    policy=Integrate(),
                    window=Day(1),
                )), every=Day(1)),
            ModelSpec(DailySoilStateModel(); name=:daily_soil, on=One(scale=:Soil), every=Day(1)),
        ),
        environment=[(duration=Hour(1),) for _ in 1:48],
    )
    compiled = Advanced.refresh_bindings!(model)
    schedule = Dict(row.application_id => row for row in explain_schedule(compiled))
    @test schedule[:hourly_flux].dt_seconds == 3600.0
    @test schedule[:daily_plant].dt_seconds == 86_400.0
    @test schedule[:daily_soil].dt_steps == 24.0

    simulation = run!(model; steps=23, outputs=:all)
    continue!(simulation; steps=25)
    @test current_step(simulation) == 48
    statuses = Dict(object.id.value => object.status for object in model_objects(model))
    @test all(statuses[id].hourly_runs == 48 for id in
              (:plant_1_leaf_1, :plant_1_leaf_2, :plant_2_leaf_1, :plant_2_leaf_2))
    @test statuses[:plant_1].daily_runs == 2
    @test statuses[:plant_2].daily_runs == 2
    @test statuses[:soil].soil_runs == 2
    @test statuses[:plant_1].daily_total == 72.0
    @test statuses[:plant_2].daily_total == 720.0

    plant_1_values = last.(outputs(simulation)[
        (:daily_plant, ObjectId(:plant_1), :daily_total)
    ])
    plant_2_values = last.(outputs(simulation)[
        (:daily_plant, ObjectId(:plant_2), :daily_total)
    ])
    @test plant_1_values == [3.0, 72.0]
    @test plant_2_values == [30.0, 720.0]
    @test all(isfinite, vcat(plant_1_values, plant_2_values))
end

@testset "event-driven cadence dispatch avoids non-due execution groups" begin
    log = Tuple{Int,Symbol}[]
    cadences = (1, 2, 4, 6)
    object_names = Tuple(Symbol(:slot_, index) for index in eachindex(cadences))
    model = CompositeModel(
        (
            Object(
                object_name;
                name=object_name,
                scale=:ScheduleSlot,
            )
            for object_name in object_names
        )...;
        applications=Tuple(
            ModelSpec(
                EventScheduleProbeModel(
                    Symbol(:cadence_, cadence),
                    log,
                );
                name=Symbol(:cadence_, cadence),
                on=One(
                    scale=:ScheduleSlot,
                    id=object_names[index],
                ),
                every=Hour(cadence),
            )
            for (index, cadence) in pairs(cadences)
        ),
        environment=(duration=Hour(1),),
    )
    simulation = run!(model; steps=8, outputs=:none, performance=true)
    performance = Advanced.runtime_performance(simulation)
    expected_visits = 8 + 4 + 2 + 2
    @test performance.counts[:application_schedule_dispatches] == 8
    @test performance.counts[:application_schedule_entries_due] ==
          expected_visits
    @test performance.counts[:application_groups_considered] == expected_visits
    @test performance.counts[:application_groups_visited] == expected_visits
    @test performance.counts[:execution_batches_visited] == expected_visits
    @test performance.counts[:application_schedule_generic_checks] == 0
    @test log[1:4] == [
        (1, :cadence_1),
        (1, :cadence_2),
        (1, :cadence_4),
        (1, :cadence_6),
    ]
    @test [pair for pair in log if first(pair) == 5] == [
        (5, :cadence_1),
        (5, :cadence_2),
        (5, :cadence_4),
    ]

    schedule = Dict(
        row.application_id => row
        for row in explain_schedule(simulation)
    )
    @test schedule[:cadence_1].schedule_kind == :always
    @test schedule[:cadence_4].schedule_kind == :periodic_integer
    @test schedule[:cadence_4].period_steps == 4
    @test schedule[:cadence_4].phase_step == 1
    @test all(row.event_driven for row in values(schedule))
end

@testset "non-due batches synchronize retained contexts when next due" begin
    log = Tuple{Int,Symbol}[]
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf_1; scale=:Leaf, parent=:scene),
        Object(:leaf_2; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(
                EventScheduleProbeModel(:leaf_probe, log);
                name=:leaf_probe,
                on=Many(scale=:Leaf),
                every=Hour(2),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    simulation = run!(model; steps=1, outputs=:all)
    batch = only(simulation.execution_plan.batches)
    contexts = getproperty.(batch.targets, :context)
    initial_compiled = simulation.compiled
    initial_environment_bindings = simulation.environment_bindings

    register_object!(
        model,
        Object(:unmatched_axis; scale=:Axis, parent=:scene),
    )
    continue!(simulation)

    @test only(simulation.execution_plan.batches) === batch
    @test simulation.compiled !== initial_compiled
    @test batch.context_state.compiled === initial_compiled
    @test batch.context_state.environment_bindings ===
          initial_environment_bindings
    @test all(context -> context.time == 1.0, contexts)

    continue!(simulation)

    @test batch.context_state.compiled === simulation.compiled
    @test batch.context_state.environment_bindings ===
          simulation.environment_bindings
    @test all(contexts) do context
        context.compiled === simulation.compiled &&
            context.environment_bindings ===
            simulation.environment_bindings &&
            context.time == 3.0
    end
    @test all(
        object -> object.status.runs == 2,
        model_objects(model; scale=:Leaf),
    )
    @test log == [
        (1, :leaf_probe),
        (1, :leaf_probe),
        (3, :leaf_probe),
        (3, :leaf_probe),
    ]
end

@testset "generic clocks retain phase semantics" begin
    model = CompositeModel(
        Object(:generic_slot; scale=:ScheduleSlot);
        applications=(
            ModelSpec(
                GenericEventScheduleProbeModel();
                name=:generic_probe,
                on=One(scale=:ScheduleSlot),
            ),
        ),
    )
    simulation = run!(model; steps=8, outputs=:none, performance=true)
    @test only(model_objects(model)).status.runs == 2
    performance = Advanced.runtime_performance(simulation)
    @test performance.counts[:application_schedule_generic_checks] == 8
    @test performance.counts[:application_schedule_entries_due] == 2
    @test performance.counts[:application_groups_considered] == 2
    schedule = only(explain_schedule(simulation))
    @test schedule.schedule_kind == :generic
    @test !schedule.event_driven
    @test schedule.phase == 0.5
end

function _event_schedule_growth_scene(growth_first::Bool, leaf_id::Symbol)
    log = Tuple{Int,Symbol}[]
    growth = ModelSpec(
        EventScheduleGrowthModel(leaf_id);
        name=:growth,
        on=One(scale=:Scene),
        every=Hour(2),
    )
    probe = ModelSpec(
        EventScheduleProbeModel(:leaf_probe, log);
        name=:leaf_probe,
        on=Many(scale=:Leaf),
        every=Hour(2),
    )
    model = CompositeModel(
        Object(:scene; scale=:Scene);
        applications=growth_first ? (growth, probe) : (probe, growth),
        environment=(duration=Hour(1),),
    )
    return model, log
end

@testset "lifecycle activation respects the due mutation barrier" begin
    later_model, later_log =
        _event_schedule_growth_scene(true, :later_leaf)
    later_simulation = run!(
        later_model;
        steps=1,
        outputs=:none,
        performance=true,
    )
    later_schedule = later_simulation.execution_plan.schedule
    @test later_log == [(1, :leaf_probe)]
    @test only(model_objects(later_model; scale=:Leaf)).status.runs == 1
    @test later_simulation.execution_plan.schedule === later_schedule

    earlier_model, earlier_log =
        _event_schedule_growth_scene(false, :earlier_leaf)
    earlier_simulation = run!(
        earlier_model;
        steps=1,
        outputs=:none,
        performance=true,
    )
    earlier_schedule = earlier_simulation.execution_plan.schedule
    @test isempty(earlier_log)
    @test only(model_objects(earlier_model; scale=:Leaf)).status.runs == 0
    @test earlier_simulation.execution_plan.schedule === earlier_schedule
    continue!(earlier_simulation; steps=2)
    @test earlier_log == [(3, :leaf_probe)]
    @test only(model_objects(earlier_model; scale=:Leaf)).status.runs == 1
    @test earlier_simulation.execution_plan.schedule === earlier_schedule
end
