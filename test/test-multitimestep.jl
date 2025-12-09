
using Dates

# Several of these tests aren't great, some are lacking corner-cases

# Note that many of the models don't specify a timestep range, leaving it to the default
# if you copy-paste this elsewhere, bear in mind that you might need to specify it

@testset "Model timestep range checks" begin

    PlantSimEngine.@process "ToyRange" verbose = false

    struct MyToyRangeModel <: AbstractToyrangeModel end

    PlantSimEngine.inputs_(m::MyToyRangeModel) = NamedTuple()
    PlantSimEngine.outputs_(m::MyToyRangeModel) = (c=-Inf,)

    PlantSimEngine.timestep_range_(m::MyToyRangeModel) = TimestepRange(Day(1), Day(3))

    function PlantSimEngine.run!(m::MyToyRangeModel, models, status, meteo, constants=nothing, extra=nothing)
        status.c = meteo.T
    end

    meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)

    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))

    mapping = Dict("Default" => (MyToyRangeModel(),))

    # Current default is Day(1)
    orch_inside = Orchestrator()
    orch_outside = Orchestrator(Week(1))

    @test_nowarn run!(mtg, mapping, meteo_day, orchestrator=orch_inside)
    @test_throws "Model MyToyRangeModel() has a provided timestep (1 week) outside of its accepted range : (1 day, 3 days)" run!(mtg, mapping, meteo_day, orchestrator=orch_outside)

end

# This is only a small subset of possible errors, unfortunately, many more corner-cases can be added
@testset "MultiScaleModel errors correctly" begin

    PlantSimEngine.@process "Toy" verbose = false

    struct MyToyModel <: AbstractToyModel end

    PlantSimEngine.inputs_(m::MyToyModel) = (a=-Inf, b=-Inf)
    PlantSimEngine.outputs_(m::MyToyModel) = (c=-Inf, d=-Inf)

    function PlantSimEngine.run!(m::MyToyModel, models, status, meteo, constants=nothing, extra=nothing)
        status.a = meteo.T
    end


    @test_throws "Variable a is part of a timestep mapping but not an output of the model MyToyModel()" MultiScaleModel(model=MyToyModel(),
        mapped_variables=[],
        timestep_mapped_variables=[TimestepMappedVariable(:a, :a, Week(1), maximum),]
    )

    m1 = MultiScaleModel(model=MyToyModel(),
        mapped_variables=[],
        timestep_mapped_variables=[TimestepMappedVariable(:c, :a, Week(1), maximum),]
    )

    mapping = Dict("Default" => (m1, Status(b=1, a=0)))
    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))

    @test_nowarn run!(mtg, mapping, meteo_day)

    @test_throws "Timestep mapping for model MyToyModel() requires variable e, but it is not a variable of the model." MultiScaleModel(model=MyToyModel(),
        mapped_variables=[],
        timestep_mapped_variables=[TimestepMappedVariable(:e, :a, Week(1), maximum),]
    )

    # This syntax errors, but should be valid, really
    @test_broken MultiScaleModel(model=MyToyModel(), timestep_mapped_variables=[TimestepMappedVariable(:a, :m, Week(1), maximum),])

    orch = Orchestrator(Week(2))
    @test_throws AssertionError run!(mtg, mapping, orchestrator=orch)

end

###########################
# Simple test with an orchestrator
###########################
using MultiScaleTreeGraph
using PlantSimEngine
using PlantMeteo
using PlantMeteo.Dates
using Test

@testset "Simple timestep mapping example" begin

    PlantSimEngine.@process "ToyDay" verbose = false

    struct MyToyDayModel <: AbstractToydayModel end

    PlantSimEngine.inputs_(m::MyToyDayModel) = (a=1,)
    PlantSimEngine.outputs_(m::MyToyDayModel) = (daily_temperature=-Inf,)

    function PlantSimEngine.run!(m::MyToyDayModel, models, status, meteo, constants=nothing, extra=nothing)
        status.daily_temperature = meteo.T
    end

    PlantSimEngine.@process "ToyWeek" verbose = false

    struct MyToyWeekModel <: AbstractToyweekModel
        temperature_threshold::Float64
    end

    MyToyWeekModel() = MyToyWeekModel(15.0)
    function PlantSimEngine.inputs_(::MyToyWeekModel)
        (weekly_max_temperature=-Inf,)
    end
    PlantSimEngine.outputs_(m::MyToyWeekModel) = (hot=false,)

    function PlantSimEngine.run!(m::MyToyWeekModel, models, status, meteo, constants=nothing, extra=nothing)
        status.hot = status.weekly_max_temperature > m.temperature_threshold
    end

    PlantSimEngine.timestep_range_(m::MyToyWeekModel) = TimestepRange(Week(1))

    meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)

    m_multiscale = Dict("Default" => (
            MultiScaleModel(model=MyToyDayModel(),
                mapped_variables=[],
                timestep_mapped_variables=[TimestepMappedVariable(:daily_temperature, :weekly_max_temperature, Week(1), maximum),]
            ),
            Status(a=1,)
        ),
        "Default2" => (
            MultiScaleModel(model=MyToyWeekModel(),
                mapped_variables=[:weekly_max_temperature => "Default" => :weekly_max_temperature],
                timestep_mapped_variables=PlantSimEngine.TimestepMappedVariable[],
            ),
        ),)


    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
    mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 2))

    mtsm = PlantSimEngine.ModelTimestepMapping(MyToyWeekModel, "Default2", Week(1))

    orch2 = PlantSimEngine.Orchestrator(Day(1), [mtsm,])

    #out = @run run!(mtg, m_multiscale, meteo_day, orchestrator=orch2)
    out = run!(mtg, m_multiscale, meteo_day, orchestrator=orch2)

    temps = [out["Default"][i].daily_temperature for i in 1:365]
    temp_m = maximum(temps)

    # At least one week should have max temp > 28
    @test temp_m > 28 && unique!([out["Default2"][i].hot for i in 1:365]) == [0, 1]
end

###########################
# Test with three timesteps, multiscale
###########################


PlantSimEngine.@process "ToyDay2" verbose = false

struct MyToyDay2Model <: AbstractToyday2Model end

PlantSimEngine.inputs_(m::MyToyDay2Model) = NamedTuple()
PlantSimEngine.outputs_(m::MyToyDay2Model) = (out_day=-Inf,)

function PlantSimEngine.run!(m::MyToyDay2Model, models, status, meteo, constants=nothing, extra=nothing)
    status.out_day = meteo.data
end

PlantSimEngine.@process "ToyWeek2" verbose = false

struct MyToyWeek2Model <: AbstractToyweek2Model end

PlantSimEngine.inputs_(::MyToyWeek2Model) = (in_week=-Inf,)
PlantSimEngine.outputs_(m::MyToyWeek2Model) = (out_week=-Inf,)

function PlantSimEngine.run!(m::MyToyWeek2Model, models, status, meteo, constants=nothing, extra=nothing)
    status.out_week = status.in_week
end

PlantSimEngine.timestep_range_(m::MyToyWeek2Model) = TimestepRange(Week(1))


PlantSimEngine.@process "ToyFourWeek2" verbose = false

struct MyToyFourWeek2Model <: AbstractToyfourweek2Model end

PlantSimEngine.inputs_(::MyToyFourWeek2Model) = (in_four_week_from_week=-Inf, in_four_week_from_day=-Inf,)
PlantSimEngine.outputs_(m::MyToyFourWeek2Model) = (inputs_agreement=false,)

function PlantSimEngine.run!(m::MyToyFourWeek2Model, models, status, meteo, constants=nothing, extra=nothing)
    status.inputs_agreement = status.in_four_week_from_week == status.in_four_week_from_day
end

PlantSimEngine.timestep_range_(m::MyToyFourWeek2Model) = TimestepRange(Week(4))

@testset "Examples with three timesteps" begin
    @testset "Three timesteps, multiscale" begin

        df = DataFrame(:data => [1 for i in 1:365],)

        mtsm_w = PlantSimEngine.ModelTimestepMapping(MyToyWeek2Model, "Default2", Week(1))
        mtsm_w4 = PlantSimEngine.ModelTimestepMapping(MyToyFourWeek2Model, "Default3", Week(4))

        orch2 = PlantSimEngine.Orchestrator(Day(1), [mtsm_w, mtsm_w4])


        m_multiscale = Dict("Default" => (
                MultiScaleModel(model=MyToyDay2Model(),
                    mapped_variables=[],
                    timestep_mapped_variables=[TimestepMappedVariable(:out_day, :out_week_from_day, Week(1), sum),
                        TimestepMappedVariable(:out_day, :out_four_week_from_day, Week(4), sum),]
                ),
            ),
            "Default2" => (
                MultiScaleModel(model=MyToyWeek2Model(),
                    mapped_variables=[:in_week => "Default" => :out_week_from_day],
                    timestep_mapped_variables=[TimestepMappedVariable(:out_week, :out_four_week_from_week, Week(4), sum),]
                ),
            ),
            "Default3" => (
                MultiScaleModel(model=MyToyFourWeek2Model(),
                    mapped_variables=[
                        :in_four_week_from_day => "Default" => :out_four_week_from_day,
                        :in_four_week_from_week => "Default2" => :out_four_week_from_week,
                    ],
                ),),
        )


        # TODO test with multiple nodes
        mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
        mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 2))
        mtg3 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default3", 1, 3))

        out = run!(mtg, m_multiscale, df, orchestrator=orch2)

        @test unique([out["Default3"][i].in_four_week_from_day for i in 1:length(out["Default3"])]) == [-Inf, 28.0]
        @test unique([out["Default3"][i].in_four_week_from_week for i in 1:length(out["Default3"])]) == [-Inf, 28.0]

        # Note : until the models actually run, inputs_agreement defaults to false, so it's only expected to be true
        # from day 28 onwards
        @test unique([out["Default3"][i].inputs_agreement for i in 28:length(out["Default3"])]) == [1]
    end


    ###########################
    # Three timestep model that is single-scale, to circumvent refvector/refvalue overwriting
    # (eg filtering out timestep-mapped variables from vars_need_init and storing the values elsewhere)
    # and check mapping at the same scale
    ###########################

    @testset "Three timesteps, single-scale" begin

        # This example has variable renaming at the same scale
        df = DataFrame(:data => [1 for i in 1:365],)

        m_singlescale_mapped = Dict("Default" => (
            MultiScaleModel(model=MyToyDay2Model(),
                mapped_variables=[],
                timestep_mapped_variables=[TimestepMappedVariable(:out_day, :out_week_from_day, Week(1), sum),
                    TimestepMappedVariable(:out_day, :out_four_week_from_day, Week(4), sum),]
            ),
            MultiScaleModel(model=MyToyWeek2Model(),
                mapped_variables=[:in_week => "Default" => :out_week_from_day],
                timestep_mapped_variables=[TimestepMappedVariable(:out_week, :out_four_week_from_week, Week(4), sum),]
            ),
            MultiScaleModel(model=MyToyFourWeek2Model(),
                mapped_variables=[
                    :in_four_week_from_day => "Default" => :out_four_week_from_day,
                    :in_four_week_from_week => "Default" => :out_four_week_from_week,
                ],
            ),))

        # This one reuses the variable names directly, so requires only timestep mapping
        m_singlescale = Dict("Default" => (
            MultiScaleModel(model=MyToyDay2Model(),
                mapped_variables=[],
                timestep_mapped_variables=[TimestepMappedVariable(:out_day, :in_week, Week(1), sum),
                    TimestepMappedVariable(:out_day, :in_four_week_from_day, Week(4), sum),]
            ),
            MultiScaleModel(model=MyToyWeek2Model(),
                mapped_variables=[],
                timestep_mapped_variables=[TimestepMappedVariable(:out_week, :in_four_week_from_week, Week(4), sum),]
            ),
            MyToyFourWeek2Model(),
        ))

        mtsm_w = PlantSimEngine.ModelTimestepMapping(MyToyWeek2Model, "Default", Week(1))
        mtsm_w4 = PlantSimEngine.ModelTimestepMapping(MyToyFourWeek2Model, "Default", Week(4))

        orch2 = PlantSimEngine.Orchestrator(Day(1), [mtsm_w, mtsm_w4])

        mtg_single = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
        out = run!(mtg_single, m_singlescale, df, orchestrator=orch2)

        @test unique([out["Default"][i].in_four_week_from_day for i in 1:length(out["Default"])]) == [-Inf, 28.0]
        @test unique([out["Default"][i].in_four_week_from_week for i in 1:length(out["Default"])]) == [-Inf, 28.0]

        @test unique([out["Default"][i].inputs_agreement for i in 1:27]) == [0]
        @test unique([out["Default"][i].inputs_agreement for i in 28:length(out["Default"])]) == [1]

        # TODO this throws an error due to mapping constraints at the same scale
        @test_broken out = run!(mtg_single, m_singlescale_mapped, df, orchestrator=orch2)

    end
end


###########################
# Test with a D -> W -> D configuration, with multiple variables mapped between timesteps
###########################

@testset "D -> W -> D configuration" begin

    PlantSimEngine.@process "ToyDayDWD" verbose = false

    struct MyToyDayDWDModel <: AbstractToydaydwdModel end

    PlantSimEngine.inputs_(m::MyToyDayDWDModel) = (a=1,)
    PlantSimEngine.outputs_(m::MyToyDayDWDModel) = (daily_temperature=-Inf,)

    function PlantSimEngine.run!(m::MyToyDayDWDModel, models, status, meteo, constants=nothing, extra=nothing)
        status.daily_temperature = meteo.data
    end

    PlantSimEngine.@process "ToyWeekDWD" verbose = false

    struct MyToyWeekDWDModel <: AbstractToyweekdwdModel
        temperature_threshold::Float64
    end

    MyToyWeekDWDModel() = MyToyWeekDWDModel(30.0)
    function PlantSimEngine.inputs_(::MyToyWeekDWDModel)
        (weekly_max_temperature=-Inf, weekly_sum_temperature=-Inf)
    end
    PlantSimEngine.outputs_(m::MyToyWeekDWDModel) = (hot=false, sum=-Inf, week_ran=false)

    function PlantSimEngine.run!(m::MyToyWeekDWDModel, models, status, meteo, constants=nothing, extra=nothing)
        status.hot = status.weekly_max_temperature > m.temperature_threshold
        status.sum += status.weekly_sum_temperature
        status.week_ran = !status.week_ran
    end

    PlantSimEngine.timestep_range_(m::MyToyWeekDWDModel) = TimestepRange(Week(1))

    PlantSimEngine.@process "ToyDayDWDOut" verbose = false

    struct MyToyDayDWDOutModel <: AbstractToydaydwdoutModel end

    PlantSimEngine.inputs_(m::MyToyDayDWDOutModel) = (sum=-Inf, daily_temperature=-Inf, week_ran=false, weekly_sum_temperature=-Inf,)
    PlantSimEngine.outputs_(m::MyToyDayDWDOutModel) = (out=-Inf, week_ran_previous=false)

    function PlantSimEngine.run!(m::MyToyDayDWDOutModel, models, status, meteo, constants=nothing, extra=nothing)
        if status.week_ran != status.week_ran_previous
            status.out -= status.weekly_sum_temperature
            status.week_ran_previous = status.week_ran
        end
        status.out += status.daily_temperature
    end

    df = DataFrame(:data => [1 for i in 1:365],)

    m_dwd = Dict("Default" => (
            MultiScaleModel(
                model=MyToyDayDWDModel(),
                mapped_variables=[],
                timestep_mapped_variables=[TimestepMappedVariable(:daily_temperature, :weekly_max_temperature, Week(1), maximum),
                    TimestepMappedVariable(:daily_temperature, :weekly_sum_temperature, Week(1), sum),
                ]),
            MultiScaleModel(
                model=MyToyDayDWDOutModel(),
                mapped_variables=[:sum => "Default2", :week_ran => "Default2",]
            ),
            Status(a=1, out=0.0,)
        ),
        "Default2" => (
            MultiScaleModel(model=MyToyWeekDWDModel(),
                mapped_variables=[:weekly_max_temperature => "Default", :weekly_sum_temperature => "Default"],
            ),
            Status(weekly_max_temperature=0.0, weekly_sum_temperature=0.0, sum=0.0, week_ran=false, week_ran_previous=false)
        ),
    )

    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
    mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 2))

    mtsm_dwd = PlantSimEngine.ModelTimestepMapping(MyToyWeekDWDModel, "Default2", Week(1))
    orch_dwd = PlantSimEngine.Orchestrator(Day(1), [mtsm_dwd,])

    out = run!(mtg, m_dwd, df, orchestrator=orch_dwd)

    #convoluted test
    @test unique!([out["Default"][i].weekly_sum_temperature for i in 1:6]) == [-Inf]
    @test !in(unique!([out["Default"][i].weekly_sum_temperature for i in 7:364]), -Inf)
    @test unique!([out["Default"][i].out == i % 7 for i in 1:365]) == [1]
end

##################################
# Two variables timestep-mapped
##################################

@testset "Two timestep-mapped variables" begin

    PlantSimEngine.@process "ToyDayDWD" verbose = false

    struct MyToyDayDWDModel <: AbstractToydaydwdModel end

    PlantSimEngine.inputs_(m::MyToyDayDWDModel) = (a=1,)
    PlantSimEngine.outputs_(m::MyToyDayDWDModel) = (daily_temperature=-Inf,)

    function PlantSimEngine.run!(m::MyToyDayDWDModel, models, status, meteo, constants=nothing, extra=nothing)
        status.daily_temperature = meteo.T
    end

    PlantSimEngine.@process "ToyWeekDWD" verbose = false

    struct MyToyWeekDWDModel <: AbstractToyweekdwdModel
        temperature_threshold::Float64
    end

    MyToyWeekDWDModel() = MyToyWeekDWDModel(30.0)
    function PlantSimEngine.inputs_(::MyToyWeekDWDModel)
        (weekly_max_temperature=-Inf, weekly_sum_temperature=-Inf)
    end
    PlantSimEngine.outputs_(m::MyToyWeekDWDModel) = (hot=false, sum=-Inf)

    function PlantSimEngine.run!(m::MyToyWeekDWDModel, models, status, meteo, constants=nothing, extra=nothing)
        status.hot = status.weekly_max_temperature > m.temperature_threshold
        status.sum += status.weekly_sum_temperature
    end

    PlantSimEngine.timestep_range_(m::MyToyWeekDWDModel) = TimestepRange(Week(1))

    #df = DataFrame(:data => [1 for i in 1:365], )
    meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)

    m_dwd = Dict("Default" => (
            MultiScaleModel(model=MyToyDayDWDModel(),
                mapped_variables=[],
                timestep_mapped_variables=[TimestepMappedVariable(:daily_temperature, :weekly_max_temperature, Week(1), maximum),
                    TimestepMappedVariable(:daily_temperature, :weekly_sum_temperature, Week(1), sum),
                ]
            ),
            Status(a=1,)
        ),
        "Default2" => (
            MultiScaleModel(model=MyToyWeekDWDModel(),
                mapped_variables=[:weekly_max_temperature => "Default", :weekly_sum_temperature => "Default"],
            ),
            Status(weekly_max_temperature=0.0, weekly_sum_temperature=0.0, sum=0.0)
        ),
    )


    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
    mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 2))

    mtsm_dwd = PlantSimEngine.ModelTimestepMapping(MyToyWeekDWDModel, "Default2", Week(1))

    orch_dwd = PlantSimEngine.Orchestrator(Day(1), [mtsm_dwd,])

    out = run!(mtg, m_dwd, meteo_day, orchestrator=orch_dwd)

    # Crude, should be expanded
    @test unique!([out["Default"][i].weekly_sum_temperature for i in 1:6]) == [-Inf]
    @test !in(unique!([out["Default"][i].weekly_sum_temperature for i in 7:364]), -Inf)
    @test unique!([out["Default"][i].weekly_max_temperature * 7 >= out["Default"][i].weekly_sum_temperature for i in 7:365]) == [1]
    @test length(unique!([out["Default"][i].weekly_sum_temperature for i in 1:365])) == 53
end

##########################
# Two models, D -> W, but D has two MTG nodes
##########################

@testset "D -> W, D has two MTG nodes" begin

    PlantSimEngine.@process "ToyDay" verbose = false

    struct MyToyDayModel <: AbstractToydayModel end

    PlantSimEngine.inputs_(m::MyToyDayModel) = (a=1,)
    PlantSimEngine.outputs_(m::MyToyDayModel) = (daily_temperature=-Inf,)

    function PlantSimEngine.run!(m::MyToyDayModel, models, status, meteo, constants=nothing, extra=nothing)
        status.daily_temperature = meteo.T
    end

    PlantSimEngine.@process "ToyWeek" verbose = false

    struct MyToyWeekModel <: AbstractToyweekModel
        temperature_threshold::Float64
    end

    MyToyWeekModel() = MyToyWeekModel(30.0)
    function PlantSimEngine.inputs_(::MyToyWeekModel)
        (weekly_max_temperature=[-Inf],)
    end
    PlantSimEngine.outputs_(m::MyToyWeekModel) = (hot=false,)

    function PlantSimEngine.run!(m::MyToyWeekModel, models, status, meteo, constants=nothing, extra=nothing)
        status.hot = status.weekly_max_temperature > m.temperature_threshold
    end

    PlantSimEngine.timestep_range_(m::MyToyWeekModel) = TimestepRange(Week(1))


    meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)

    m_multiscale = Dict("Default" => (
            MultiScaleModel(
                model=MyToyDayModel(),
                mapped_variables=[],
                timestep_mapped_variables=[TimestepMappedVariable(:daily_temperature, :weekly_temperature, Week(1), maximum)],
            ),
            Status(a=1,)
        ),
        "Default2" => (
            MultiScaleModel(model=MyToyWeekModel(),
                mapped_variables=[:weekly_max_temperature => "Default" => :weekly_temperature],
            ),
        ),)


    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 1))
    mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Default", 1, 1))
    mtg3 = Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Default", 1, 2))

    mtsm = PlantSimEngine.ModelTimestepMapping(MyToyWeekModel, "Default2", Week(1))
    orch2 = PlantSimEngine.Orchestrator(Day(1), [mtsm,])
    out = run!(mtg, m_multiscale, meteo_day, orchestrator=orch2)

    # Again, this doesn't test as much as it could
    @test unique!([out["Default2"][i].weekly_max_temperature for i in 1:6]) == [-Inf]
    @test !in(unique!([out["Default2"][i].weekly_max_temperature for i in 7:364]), -Inf)
    @test length(unique!([out["Default2"][i].weekly_max_temperature for i in 1:365])) == 53
end

##########################
# Two models, D -> W, but D has two MTG nodes, and we map as a refvector
##########################

@testset "D -> W, D has two nodes and we map as a refvector" begin

    PlantSimEngine.@process "ToyDay" verbose = false

    struct MyToyDayModel <: AbstractToydayModel end

    PlantSimEngine.inputs_(m::MyToyDayModel) = (a=1,)
    PlantSimEngine.outputs_(m::MyToyDayModel) = (daily_temperature=-Inf,)

    function PlantSimEngine.run!(m::MyToyDayModel, models, status, meteo, constants=nothing, extra=nothing)
        status.daily_temperature = meteo.T
    end

    PlantSimEngine.@process "ToyWeek" verbose = false

    struct MyToyWeekModel <: AbstractToyweekModel
        temperature_threshold::Float64
    end

    MyToyWeekModel() = MyToyWeekModel(30.0)
    function PlantSimEngine.inputs_(::MyToyWeekModel)
        (weekly_max_temperature=[-Inf],)
    end
    PlantSimEngine.outputs_(m::MyToyWeekModel) = (refvector=false,)

    function PlantSimEngine.run!(m::MyToyWeekModel, models, status, meteo, constants=nothing, extra=nothing)
        status.refvector = status.weekly_max_temperature[1] == status.weekly_max_temperature[2]
    end

    PlantSimEngine.timestep_range_(m::MyToyWeekModel) = TimestepRange(Week(1))


    meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)

    m_multiscale = Dict("Default" => (
            MultiScaleModel(
                model=MyToyDayModel(),
                mapped_variables=[],
                timestep_mapped_variables=[TimestepMappedVariable(:daily_temperature, :weekly_temperature, Week(1), maximum)],
            ),
            Status(a=1,)
        ),
        "Default2" => (
            MultiScaleModel(model=MyToyWeekModel(),
                mapped_variables=[:weekly_max_temperature => ["Default" => :weekly_temperature]],
            ),
        ),)


    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 1))
    mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Default", 1, 1))
    mtg3 = Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Default", 1, 2))

    mtsm = PlantSimEngine.ModelTimestepMapping(MyToyWeekModel, "Default2", Week(1))

    orch2 = PlantSimEngine.Orchestrator(Day(1), [mtsm,])

    # TODO The RefVector will be in the outputs, so intermediate data is lost for such timestep-mapped variables, and it makes the outputs confusing
    out = run!(mtg, m_multiscale, meteo_day, orchestrator=orch2)

    @test unique!([out["Default2"][i].refvector for i in 1:6]) == [false]
    @test unique!([out["Default2"][i].refvector for i in 7:365]) == [true]

end

##########################
# Two models, D -> W, but both D and W have two MTG nodes
##########################

@testset "D -> W, both D and W have two nodes" begin

    PlantSimEngine.@process "ToyDay" verbose = false

    struct MyToyDayModel <: AbstractToydayModel end

    PlantSimEngine.inputs_(m::MyToyDayModel) = (a=1,)
    PlantSimEngine.outputs_(m::MyToyDayModel) = (daily_temperature=-Inf,)

    function PlantSimEngine.run!(m::MyToyDayModel, models, status, meteo, constants=nothing, extra=nothing)
        status.daily_temperature = meteo.T + node_id(status.node)
    end

    PlantSimEngine.@process "ToyWeek" verbose = false

    struct MyToyWeekModel <: AbstractToyweekModel
        temperature_threshold::Float64
    end

    MyToyWeekModel() = MyToyWeekModel(30.0)
    function PlantSimEngine.inputs_(::MyToyWeekModel)
        (weekly_max_temperature=[-Inf],)
    end
    PlantSimEngine.outputs_(m::MyToyWeekModel) = (refvector=false,)

    function PlantSimEngine.run!(m::MyToyWeekModel, models, status, meteo, constants=nothing, extra=nothing)
        status.refvector = status.weekly_max_temperature[1] + 1 == status.weekly_max_temperature[2]
    end

    PlantSimEngine.timestep_range_(m::MyToyWeekModel) = TimestepRange(Week(1))

    meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)

    m_multiscale = Dict("Default" => (
            MultiScaleModel(
                model=MyToyDayModel(),
                mapped_variables=[],
                timestep_mapped_variables=[TimestepMappedVariable(:daily_temperature, :weekly_temperature, Week(1), maximum)],
            ),
            Status(a=1,)
        ),
        "Default2" => (
            MultiScaleModel(model=MyToyWeekModel(),
                mapped_variables=[:weekly_max_temperature => ["Default" => :weekly_temperature]],
            ),
        ),)


    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 1))
    mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 1))
    mtg3 = Node(mtg2, MultiScaleTreeGraph.NodeMTG("+", "Default", 1, 1))
    mtg4 = Node(mtg2, MultiScaleTreeGraph.NodeMTG("+", "Default", 1, 2))

    mtsm = PlantSimEngine.ModelTimestepMapping(MyToyWeekModel, "Default2", Week(1))

    orch2 = PlantSimEngine.Orchestrator(Day(1), [mtsm,])

    out = run!(mtg, m_multiscale, meteo_day, orchestrator=orch2)

    @test unique!([out["Default2"][i].refvector for i in 1:12]) == [false]
    @test unique!([out["Default2"][i].refvector for i in 13:730]) == [true]
end

###########################
# Test with one timestep, multiscale + previoustimestep (single node scales only)
###########################

@testset "PreviousTimestep very simple case" begin

    PlantSimEngine.@process "ToyDay2" verbose = false

    struct MyToyDay2Model <: AbstractToyday2Model end

    PlantSimEngine.inputs_(m::MyToyDay2Model) = (in_week=-Inf,)
    PlantSimEngine.outputs_(m::MyToyDay2Model) = (out_day=-Inf,)

    function PlantSimEngine.run!(m::MyToyDay2Model, models, status, meteo, constants=nothing, extra=nothing)
        status.out_day = max(meteo.data, status.in_week / 7.0)
    end

    PlantSimEngine.@process "ToyWeek2" verbose = false

    struct MyToyWeek2Model <: AbstractToyweek2Model end

    PlantSimEngine.inputs_(::MyToyWeek2Model) = (in_week=-Inf,)
    PlantSimEngine.outputs_(m::MyToyWeek2Model) = (out_week=-Inf,)

    function PlantSimEngine.run!(m::MyToyWeek2Model, models, status, meteo, constants=nothing, extra=nothing)
        status.out_week = status.in_week
    end

    PlantSimEngine.timestep_range_(m::MyToyWeek2Model) = TimestepRange(Week(1))


    df = DataFrame(:data => [i for i in 1:365],)
    orch2 = PlantSimEngine.Orchestrator()

    m_multiscale_cyclic = Dict("Default" => (
            MultiScaleModel(model=MyToyDay2Model(),
                mapped_variables=[:in_week => "Default2" => :out_week],
                timestep_mapped_variables=[TimestepMappedVariable(:out_day, :in_week, Week(1), sum)]
            ),),
        "Default2" => (
            MultiScaleModel(model=MyToyWeek2Model(),
                mapped_variables=[:in_week => "Default" => :in_week],
            ),),)

    m_multiscale_prev_no_timestep = Dict("Default" => (
            MultiScaleModel(model=MyToyDay2Model(),
                mapped_variables=[PlantSimEngine.PreviousTimeStep(:in_week) => "Default2" => :out_week],
            ),),
        "Default2" => (
            MultiScaleModel(model=MyToyWeek2Model(),
                mapped_variables=[:in_week => "Default" => :in_week],
            ),),)

    m_multiscale_prev_and_timestep = Dict("Default" => (
            MultiScaleModel(model=MyToyDay2Model(),
                mapped_variables=[PlantSimEngine.PreviousTimeStep(:in_week) => "Default2" => :out_week],
                timestep_mapped_variables=[TimestepMappedVariable(:out_day, :in_week, Week(1), sum)]
            ),),
        "Default2" => (
            MultiScaleModel(model=MyToyWeek2Model(),
                mapped_variables=[:in_week => "Default" => :in_week],
            ),),)


    mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
    mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 2))

    mtsm = PlantSimEngine.ModelTimestepMapping(MyToyWeek2Model, "Default2", Week(1))
    orch2 = PlantSimEngine.Orchestrator(Day(1), [mtsm,])


    @test_throws AssertionError run!(mtg, m_multiscale_prev_no_timestep, df, orchestrator=orch2)
    @test_throws "Cyclic dependency detected for process ToyWeek2: ToyWeek2 for organ Default2 depends on ToyDay2 from organ Default, which depends on the first one. This is not allowed, you may need to develop a new process that does the whole computation by itself." run!(mtg, m_multiscale_cyclic, df, orchestrator=orch2)

    # Too basic
    @test_nowarn run!(mtg, m_multiscale_prev_and_timestep, df, orchestrator=orch2)
end