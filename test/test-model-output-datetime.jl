using DataFrames
using Dates
using PlantMeteo
using PlantSimEngine
using Test

PlantSimEngine.@process "output_datetime_counter" verbose = false
struct OutputDatetimeCounterModel <: AbstractOutput_Datetime_CounterModel end
PlantSimEngine.inputs_(::OutputDatetimeCounterModel) = NamedTuple()
PlantSimEngine.outputs_(::OutputDatetimeCounterModel) = (count=0.0,)
function PlantSimEngine.run!(
    ::OutputDatetimeCounterModel,
    status,
    environment,
    constants,
    context,
)
    status.count += one(status.count)
    return nothing
end

function output_datetime_model(environment; every=nothing)
    return CompositeModel(
        Object(:leaf; scale=:Leaf);
        applications=(
            ModelSpec(
                OutputDatetimeCounterModel();
                name=:counter,
                on=One(scale=:Leaf),
                every=every,
            ),
        ),
        environment=environment,
    )
end

function output_datetime_check_time_columns(table)
    rows = table isa AbstractDataFrame ? eachrow(table) : table
    @test all(row -> row.timestep isa Integer, rows)
    @test all(row -> hasproperty(row, :datetime), rows)
    @test all(row -> !hasproperty(row, :time), rows)
    return nothing
end

struct OutputDatetimeBackend <:
       PlantSimEngine.EnvironmentAPI.AbstractEnvironmentBackend end
PlantSimEngine.EnvironmentAPI.base_step_seconds(::OutputDatetimeBackend) = 3600.0
PlantSimEngine.EnvironmentAPI.get_nsteps(::OutputDatetimeBackend) = 3

PlantSimEngine.@process "output_datetime_echo" verbose = false
struct OutputDatetimeEchoModel <: AbstractOutput_Datetime_EchoModel end
PlantSimEngine.inputs_(::OutputDatetimeEchoModel) = NamedTuple()
PlantSimEngine.environment_inputs_(::OutputDatetimeEchoModel) = (date=DateTime(2000),)
PlantSimEngine.outputs_(::OutputDatetimeEchoModel) = (observed_date=DateTime(2000),)
function PlantSimEngine.run!(::OutputDatetimeEchoModel, status, environment, constants, context)
    status.observed_date = environment.date
    return nothing
end

PlantSimEngine.@process "output_datetime_controller" verbose = false
struct OutputDatetimeControllerModel <: AbstractOutput_Datetime_ControllerModel end
PlantSimEngine.inputs_(::OutputDatetimeControllerModel) = NamedTuple()
PlantSimEngine.outputs_(::OutputDatetimeControllerModel) = (step=0,)
function PlantSimEngine.run!(
    ::OutputDatetimeControllerModel,
    status,
    environment,
    constants,
    context,
)
    status.step += 1
    status.step == 2 && run_call!(context, :counter; publish=true)
    return nothing
end

@testset "output datetimes follow global publication steps" begin
    start = DateTime(2025, 6, 1, 6)
    # Uneven dates deliberately distinguish source-row matching from elapsed-time
    # arithmetic. Scheduling still uses the common one-hour row duration.
    dates = [start + Hour(offset) for offset in (0, 1, 4, 5, 9, 10)]
    weather = [(date=date, duration=Hour(1)) for date in dates]
    model = CompositeModel(
        Object(:hourly_leaf; scale=:Leaf),
        Object(:slow_leaf; scale=:Leaf),
        Object(:phased_leaf; scale=:Leaf);
        applications=(
            ModelSpec(
                OutputDatetimeCounterModel();
                name=:hourly,
                on=One(id=:hourly_leaf),
                every=Hour(1),
            ),
            ModelSpec(
                OutputDatetimeCounterModel();
                name=:slow,
                on=One(id=:slow_leaf),
                every=Hour(2),
            ),
            ModelSpec(
                OutputDatetimeCounterModel();
                name=:phased,
                on=One(id=:phased_leaf),
                every=ClockSpec(3.0, 2.0),
            ),
        ),
        environment=weather,
    )
    simulation = run!(model; steps=6, outputs=:all)
    rows = collect_outputs(simulation; sink=nothing)
    output_datetime_check_time_columns(rows)
    for (application, expected_steps) in (
        (:hourly, [1, 2, 3, 4, 5, 6]),
        (:slow, [1, 3, 5]),
        (:phased, [2, 5]),
    )
        selected = filter(row -> row.application_id == application, rows)
        @test getproperty.(selected, :timestep) == expected_steps
        @test getproperty.(selected, :datetime) == dates[expected_steps]
        @test getproperty.(selected, :value) == Float64.(1:length(expected_steps))
    end
    selected = collect_outputs(simulation, :slow_leaf, :count; sink=nothing)
    output_datetime_check_time_columns(selected)
    @test getproperty.(selected, :datetime) == dates[[1, 3, 5]]
    frame = collect_outputs(simulation)
    selected_frame = collect_outputs(simulation, :slow_leaf, :count)
    custom = collect_outputs(simulation; sink=Tuple)
    selected_custom = collect_outputs(simulation, :slow_leaf, :count; sink=Tuple)
    for table in (frame, selected_frame, custom, selected_custom)
        output_datetime_check_time_columns(table)
    end
    @test frame.datetime == getproperty.(rows, :datetime)
    @test selected_frame.datetime == dates[[1, 3, 5]]
    @test custom == Tuple(rows)
    @test selected_custom == Tuple(selected)
    @test outputs(simulation)[(:slow, ObjectId(:slow_leaf), :count)] ==
          [(1.0, 1.0), (3.0, 2.0), (5.0, 3.0)]
end

@testset "requested datetimes follow each request clock" begin
    start = DateTime(2025, 6, 1, 6)
    dates = [start + Hour(offset) for offset in (0, 1, 4, 5, 9, 10)]
    weather = [(date=date, duration=Hour(1)) for date in dates]
    requests = [
        OutputRequest(
            :Leaf,
            :count;
            name=name,
            application=:counter,
            policy=policy,
            clock=clock,
        )
        for (name, policy, clock) in (
            (:held, HoldLast(), Hour(1)),
            (:interpolated, Interpolate(), Hour(1)),
            (:integrated, Integrate(), Hour(3)),
            (:aggregated, Aggregate(), Hour(3)),
        )
    ]
    simulation = run!(
        output_datetime_model(weather; every=Hour(2));
        steps=6,
        outputs=requests,
    )
    collected = collect_outputs(simulation; sink=nothing)
    frames = collect_outputs(simulation)
    custom = collect_outputs(simulation; sink=Tuple)
    for (name, expected_steps) in (
        (:held, [1, 2, 3, 4, 5, 6]),
        (:interpolated, [1, 2, 3, 4, 5]),
        (:integrated, [1, 4]),
        (:aggregated, [1, 4]),
    )
        rows = collect_outputs(simulation, name; sink=nothing)
        frame = collect_outputs(simulation, name)
        named_custom = collect_outputs(simulation, name; sink=Tuple)
        for table in (rows, collected[name], frames[name], frame, custom[name], named_custom)
            output_datetime_check_time_columns(table)
        end
        @test rows == collected[name]
        @test getproperty.(rows, :timestep) == expected_steps
        @test getproperty.(rows, :datetime) == dates[expected_steps]
        @test frames[name].datetime == dates[expected_steps]
        @test frame.datetime == dates[expected_steps]
        @test custom[name] == Tuple(rows)
        @test named_custom == Tuple(rows)
    end
    @test getproperty.(collected[:held], :value) == [1.0, 1.0, 2.0, 2.0, 3.0, 3.0]
    # Retained producer streams keep their publication clock even when requests
    # materialize additional rows between those publications.
    raw = collect_outputs(simulation, :leaf, :count; sink=nothing)
    output_datetime_check_time_columns(raw)
    @test getproperty.(raw, :timestep) == [1, 3, 5]
    @test getproperty.(raw, :datetime) == dates[[1, 3, 5]]
end

@testset "datetime snapshots survive continuation and source mutation" begin
    start = DateTime(2025, 6, 1, 6)
    dates = [start + Hour(i) for i in 0:4]
    weather = DataFrame(date=copy(dates), duration=fill(Hour(1), 5))
    simulation = run!(output_datetime_model(weather); steps=2, outputs=:all)
    weather.date .+= Year(1)
    @test collect_outputs(simulation).datetime == dates[1:2]
    continue!(simulation; steps=2)
    step!(simulation)
    rows = collect_outputs(simulation; sink=nothing)
    @test getproperty.(rows, :timestep) == [1, 2, 3, 4, 5]
    @test getproperty.(rows, :datetime) == dates
    reference = run!(
        output_datetime_model(DataFrame(date=dates, duration=fill(Hour(1), 5)));
        steps=5,
        outputs=:all,
    )
    @test rows == collect_outputs(reference; sink=nothing)
    fresh = run!(output_datetime_model(weather); steps=1, outputs=:all)
    @test collect_outputs(fresh).datetime == [start + Year(1)]
end

@testset "datetime source types and unavailable timestamps" begin
    start = DateTime(2025, 6, 1, 6)
    singleton = run!(
        output_datetime_model((date=start, duration=Hour(1)));
        steps=3,
        outputs=:all,
    )
    @test collect_outputs(singleton).datetime == fill(start, 3)

    dates = [Date(2025, 6, 1), Date(2025, 6, 2)]
    daily = run!(
        output_datetime_model([(date=date, duration=Day(1)) for date in dates]);
        steps=2,
        outputs=:all,
    )
    @test collect_outputs(daily).datetime == DateTime.(dates)
    @test all(value -> value isa DateTime, collect_outputs(daily).datetime)

    for environment in (
        nothing,
        (duration=Hour(1),),
        (date=missing, duration=Hour(1)),
        (date="2025-06-01", duration=Hour(1)),
        [(duration=Hour(1),) for _ in 1:3],
        OutputDatetimeBackend(),
    )
        simulation = run!(output_datetime_model(environment); steps=3, outputs=:all)
        @test all(ismissing, collect_outputs(simulation).datetime)
        @test all(row -> ismissing(row.datetime), collect_outputs(simulation; sink=nothing))
    end

    mixed = DataFrame(
        date=Any[start, Date(2025, 6, 2), missing, "unknown"],
        duration=fill(Hour(1), 4),
    )
    mixed_simulation = run!(output_datetime_model(mixed); steps=4, outputs=:all)
    @test isequal(
        collect_outputs(mixed_simulation).datetime,
        [start, DateTime(2025, 6, 2), missing, missing],
    )

    weather = Weather([
        Atmosphere(
            date=start + Hour(i),
            duration=Hour(1),
            T=20.0,
            Wind=1.0,
            Rh=0.5,
        ) for i in 0:4
    ])
    sampled = run!(output_datetime_model(weather; every=Hour(2)); steps=5, outputs=:all)
    @test collect_outputs(sampled).datetime == [start, start + Hour(2), start + Hour(4)]
end

@testset "datetime labels agree with the weather received by kernels" begin
    start = DateTime(2025, 6, 1, 6)
    dates = [start + Hour(i) for i in 0:4]
    dataframe = DataFrame(date=copy(dates), duration=fill(Hour(1), 5))
    weather = Weather([
        Atmosphere(date=date, duration=Hour(1), T=20.0, Wind=1.0, Rh=0.5)
        for date in dates
    ])
    for environment in (dataframe, weather)
        model = CompositeModel(
            Object(:leaf; scale=:Leaf);
            applications=(ModelSpec(
                OutputDatetimeEchoModel(); on=One(scale=:Leaf), every=Hour(2),
            ),),
            environment=environment,
        )
        simulation = run!(model; steps=5, outputs=:all)
        rows = collect_outputs(simulation)
        @test rows.datetime == rows.value == dates[[1, 3, 5]]
        if environment === dataframe
            dataframe.date .+= Year(1)
            # The same model reuses its prepared weather rows on a fresh run.
            rerun = collect_outputs(run!(model; steps=5, outputs=:all))
            @test rerun.datetime == rerun.value == dates[[1, 3, 5]]
            @test collect_outputs(simulation).datetime == dates[[1, 3, 5]]
        end
    end
end

@testset "manual publication and held outputs retain the caller timeline" begin
    start = DateTime(2025, 6, 1, 6)
    dates = [start + Hour(i) for i in 0:3]
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(
                OutputDatetimeControllerModel();
                name=:controller,
                on=One(scale=:Scene),
                calls=(:counter => One(scale=:Leaf, application=:manual_counter),),
            ),
            ModelSpec(
                OutputDatetimeCounterModel();
                name=:manual_counter,
                on=One(scale=:Leaf),
            ),
        ),
        environment=[(date=date, duration=Hour(1)) for date in dates],
    )
    simulation = run!(
        model;
        steps=4,
        outputs=OutputRequest(
            :Leaf,
            :count;
            name=:held_manual,
            application=:manual_counter,
            policy=HoldLast(),
        ),
    )
    published = collect_outputs(simulation, :leaf, :count; sink=nothing)
    output_datetime_check_time_columns(published)
    @test getproperty.(published, :timestep) == [2]
    @test getproperty.(published, :datetime) == dates[[2]]
    held = collect_outputs(simulation, :held_manual; sink=nothing)
    output_datetime_check_time_columns(held)
    @test getproperty.(held, :timestep) == [1, 2, 3, 4]
    @test getproperty.(held, :datetime) == dates
    @test getproperty.(held, :value) == [0.0, 1.0, 1.0, 1.0]
end
