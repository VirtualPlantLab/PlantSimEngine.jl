###########################

# Simple test using an ad hoc connector model
# Broken by subsequent changes, left just in case for now (TODO remove once prototyping is over)
###########################

#=
using PlantSimEngine
# Include the example dummy processes:
using PlantSimEngine.Examples
using Test, Aqua
using Tables, DataFrames, CSV
using MultiScaleTreeGraph
using PlantMeteo, Statistics
using Documenter # for doctests

using PlantMeteo.Dates
include("helper-functions.jl")



# These models might be worth exposing in the future ?
PlantSimEngine.@process "basic_current_timestep" verbose = false

struct HelperCurrentTimestepModel <: AbstractBasic_Current_TimestepModel
end

PlantSimEngine.inputs_(::HelperCurrentTimestepModel) = (next_timestep=1,)
PlantSimEngine.outputs_(m::HelperCurrentTimestepModel) = (current_timestep=1,)

function PlantSimEngine.run!(m::HelperCurrentTimestepModel, models, status, meteo, constants=nothing, extra=nothing)
    status.current_timestep = status.next_timestep
 end 

 PlantSimEngine.ObjectDependencyTrait(::Type{<:HelperCurrentTimestepModel}) = PlantSimEngine.IsObjectDependent()
 PlantSimEngine.TimeStepDependencyTrait(::Type{<:HelperCurrentTimestepModel}) = PlantSimEngine.IsTimeStepDependent()

PlantSimEngine.timestep_range_(m::HelperCurrentTimestepModel) = Day(1)


 PlantSimEngine.@process "basic_next_timestep" verbose = false
 struct HelperNextTimestepModel <: AbstractBasic_Next_TimestepModel
 end
 
 PlantSimEngine.inputs_(::HelperNextTimestepModel) = (current_timestep=1,)
 PlantSimEngine.outputs_(m::HelperNextTimestepModel) = (next_timestep=1,)
 
 function PlantSimEngine.run!(m::HelperNextTimestepModel, models, status, meteo, constants=nothing, extra=nothing)
     status.next_timestep = status.current_timestep + 1
  end 

PlantSimEngine.timestep_range_(m::HelperNextTimestepModel) = Day(1)





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
     (weekly_max_temperature=-Inf,)
end
PlantSimEngine.outputs_(m::MyToyWeekModel) = (hot = false,)

function PlantSimEngine.run!(m::MyToyWeekModel, models, status, meteo, constants=nothing, extra=nothing)
    status.hot = status.weekly_max_temperature > m.temperature_threshold
end

PlantSimEngine.timestep_range_(m::MyToyWeekModel) = Week(1)



PlantSimEngine.@process "DWConnector" verbose = false

struct MyDwconnectorModel <: AbstractDwconnectorModel
    T_daily::Array{Float64}
end

MyDwconnectorModel() = MyDwconnectorModel(Array{Float64}(undef, 7))

function PlantSimEngine.inputs_(::MyDwconnectorModel)
     (daily_temperature=-Inf, current_timestep=1,)
end
PlantSimEngine.outputs_(m::MyDwconnectorModel) = (weekly_max_temperature = 0.0,)

function PlantSimEngine.run!(m::MyDwconnectorModel, models, status, meteo, constants=nothing, extra=nothing)
    m.T_daily[1 + (status.current_timestep % 7)] = status.daily_temperature 
    
    if(status.current_timestep % 7 == 1)
        status.weekly_max_temperature = sum(m.T_daily)/7.0
    else
        status.weekly_max_temperature = 0
    end
end

    PlantSimEngine.timestep_range_(m::MyDwconnectorModel) = Day(1)





meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)

m = Dict("Default" => (
    MyToyDayModel(), 
    MyToyWeekModel(),
    MyDwconnectorModel(), 
    HelperNextTimestepModel(),
    MultiScaleModel(
                    model=HelperCurrentTimestepModel(),
                    mapped_variables=[PreviousTimeStep(:next_timestep),],
                    ),
    Status(a=1,)))

to_initialize(m)

models_timestep = Dict(MyToyDayModel=>1, MyDwconnectorModel => 1, MyToyWeekModel =>7, HelperNextTimestepModel => 1, HelperCurrentTimestepModel => 1)

mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
 
out = run!(mtg, m, meteo_day, default_timestep=1, model_timesteps=models_timestep)


# NOTE : replace_mapping_status_vectors_with_generated_models is assumed to have already run if used
# otherwise there might be vector length conflicts with timesteps
sim = PlantSimEngine.GraphSimulation(mtg, m, nsteps=nothing, check=true, outputs=nothing, default_timestep=1, model_timesteps=models_timestep)

=#

# TODO could some mapping happen automatically for variables directly taken from weather data ?
# Does this happen often in a typical model ?



###########################
# Simple test with an orchestrator
###########################
using MultiScaleTreeGraph
using PlantSimEngine
using PlantMeteo
using PlantMeteo.Dates
using Test

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

MyToyWeekModel() = MyToyWeekModel(28.0)
function PlantSimEngine.inputs_(::MyToyWeekModel)
     (weekly_max_temperature=-Inf,)
end
PlantSimEngine.outputs_(m::MyToyWeekModel) = (hot = false,)

function PlantSimEngine.run!(m::MyToyWeekModel, models, status, meteo, constants=nothing, extra=nothing)
    status.hot = status.weekly_max_temperature > m.temperature_threshold
end

PlantSimEngine.timestep_range_(m::MyToyWeekModel) = TimestepRange(Week(1))


meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)

m_multiscale = Dict("Default" => (
    MyToyDayModel(),
    Status(a=1,)
    ),
    "Default2" => (
    MultiScaleModel(model=MyToyWeekModel(),    
    #mapped_variables=[:weekly_max_temperature => ["Default" => :daily_temperature]], # TODO test this
    mapped_variables=[:weekly_max_temperature => "Default" => :daily_temperature],
    ),
    ),)


mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 2))

to = PlantSimEngine.Var_to(:weekly_max_temperature)
from = PlantSimEngine.Var_from(MyToyDayModel, "Default", :daily_temperature, maximum)

dict_to_from = Dict(from => to)
mtsm = PlantSimEngine.ModelTimestepMapping(MyToyWeekModel, "Default2", Week(1), dict_to_from)

orch2 = PlantSimEngine.Orchestrator2(Day(1), [mtsm,])

out = run!(mtg, m_multiscale, meteo_day, orchestrator=orch2)

temps = [out["Default"][i].daily_temperature for i in 1:365]
temp_m = maximum(temps)

# At least one week should have max temp > 28
@test temp_m > 28 && unique!([out["Default2"][i].hot for i in 1:365]) == [0,1]

###########################
# Test with three timesteps, multiscale
###########################

using MultiScaleTreeGraph
using PlantSimEngine
using PlantMeteo
using PlantMeteo.Dates

PlantSimEngine.@process "ToyDay2" verbose = false

struct MyToyDay2Model <: AbstractToyday2Model end

PlantSimEngine.inputs_(m::MyToyDay2Model) = NamedTuple()
PlantSimEngine.outputs_(m::MyToyDay2Model) = (out_day=-Inf,)

function PlantSimEngine.run!(m::MyToyDay2Model, models, status, meteo, constants=nothing, extra=nothing)
    status.out_day = meteo.data
end

#=PlantSimEngine.@process "ToyDay3" verbose = false

struct MyToyDay3Model <: AbstractToyday3Model end

PlantSimEngine.inputs_(m::MyToyDay3Model) = (in_day=-Inf, in_day_summed_prev_timestep=-Inf)
PlantSimEngine.outputs_(m::MyToyDay3Model) = (out_day_summed=-Inf,)

function PlantSimEngine.run!(m::MyToyDay3Model, models, status, meteo, constants=nothing, extra=nothing)
    status.out_day_summed = status.in_day + status.in_day_summed_prev_timestep
end

PlantSimEngine.@process "ToyDay4" verbose = false

struct MyToyDay4Model <: AbstractToyday4Model end

PlantSimEngine.inputs_(m::MyToyDay4Model) = (in_day_summed=-Inf,)
PlantSimEngine.outputs_(m::MyToyDay4Model) = (out_day_summed_2= -Inf,)

function PlantSimEngine.run!(m::MyToyDay4Model, models, status, meteo, constants=nothing, extra=nothing)
    status.out_day_summed_2 = status.in_day_summed
end=#

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



df = DataFrame(:data => [1 for i in 1:365], )

    # TODO can make this optional if the timestep range is actually a single value
    model_timesteps_defaultscale = Dict(MyToyWeek2Model =>Week(1), MyToyFourWeek2Model =>Week(4), )

    to_w = PlantSimEngine.Var_to(:in_week)
    from_d = PlantSimEngine.Var_from(MyToyDay2Model, "Default", :out_day, sum)
    dict_to_from_w = Dict(from_d => to_w)

    to_w4_d = PlantSimEngine.Var_to(:in_four_week_from_day)
    to_w4_w = PlantSimEngine.Var_to(:in_four_week_from_week)
    from_w = PlantSimEngine.Var_from(MyToyWeek2Model, "Default2", :out_week, sum)

    dict_to_from_w4 = Dict(from_d => to_w4_d, from_w => to_w4_w)
    
    mtsm_w = PlantSimEngine.ModelTimestepMapping(MyToyWeek2Model, "Default2", Week(1), dict_to_from_w)
    mtsm_w4 = PlantSimEngine.ModelTimestepMapping(MyToyFourWeek2Model, "Default3", Week(4), dict_to_from_w4)

    orch2 = PlantSimEngine.Orchestrator2(Day(1), [mtsm_w, mtsm_w4])


m_multiscale = Dict("Default" => (
    MyToyDay2Model(),
    ),
    "Default2" => (
    MultiScaleModel(model=MyToyWeek2Model(),    
    mapped_variables=[:in_week => "Default" => :out_day],
    ),
    ),
    "Default3" => (
    MultiScaleModel(model=MyToyFourWeek2Model(),    
    mapped_variables=[
        :in_four_week_from_day => "Default" => :out_day,
        :in_four_week_from_week => "Default2" => :out_week,
        ],
    ),),
    #="Default4"=> (
    MultiScaleModel(
        model=MyToyDay3Model(),
        mapped_variables=[
            PlantSimEngine.PreviousTimeStep(:in_day_summed_prev_timestep) => "Default5" => :out_day_summed_2,
            :in_day => "Default" => :out_day,
            ]),
            Status(in_day_summed_prev_timestep=0,)
    ),
    "Default5" => (
    MultiScaleModel(model=MyToyDay4Model(),
    mapped_variables= [:in_day_summed => "Default4" => :out_day_summed],
    ),
    Status(in_day_summed=0,out_day_summed_2=0)
    ),=#
    )

   
# TODO test with multiple nodes
mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 2))
mtg3 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default3", 1, 3))
#mtg4 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default4", 1, 4))
#mtg5 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default5", 1, 5))

    #orch2 = PlantSimEngine.Orchestrator2()

#out = @run run!(mtg, m_multiscale, df, orchestrator=orch2)
out = run!(mtg, m_multiscale, df, orchestrator=orch2)



using Test
 @test unique([out["Default3"][i].in_four_week_from_day for i in 1:length(out["Default3"])]) == [-Inf, 28.0]
 @test unique([out["Default3"][i].in_four_week_from_week for i in 1:length(out["Default3"])]) == [-Inf, 28.0]
 
 # Note : until the models actually run, inputs_agreement defaults to false, so it's only expected to be true
 # from day 28 onwards
 @test unique([out["Default3"][i].inputs_agreement for i in 28:length(out["Default3"])]) == [1]

 ###########################
# Three timestep model that is single-scale, to circumvent refvector/refvalue overwriting
# (eg filtering out timestep-mapped variables from vars_need_init and storing the values elsewhere)
# and check mapping at the same scale
###########################

 m_singlescale = Dict("Default" => (
    MyToyDay2Model(),
    MyToyWeek2Model(),    
    MyToyFourWeek2Model(),    
    ),)


    model_timesteps_defaultscale = Dict(MyToyWeek2Model =>Week(1), MyToyFourWeek2Model =>Week(4), )
    to_w = PlantSimEngine.Var_to(:in_week)
    from_d = PlantSimEngine.Var_from(MyToyDay2Model, "Default", :out_day, sum)
    dict_to_from_w = Dict(from_d => to_w)

    to_w4_d = PlantSimEngine.Var_to(:in_four_week_from_day)
    to_w4_w = PlantSimEngine.Var_to(:in_four_week_from_week)
    from_w = PlantSimEngine.Var_from(MyToyWeek2Model, "Default", :out_week, sum)

    dict_to_from_w4 = Dict(from_d => to_w4_d, from_w => to_w4_w)
    
    mtsm_w = PlantSimEngine.ModelTimestepMapping(MyToyWeek2Model, "Default", Week(1), dict_to_from_w)
    mtsm_w4 = PlantSimEngine.ModelTimestepMapping(MyToyFourWeek2Model, "Default", Week(4), dict_to_from_w4)

    orch2 = PlantSimEngine.Orchestrator2(Day(1), [mtsm_w, mtsm_w4])

    mtg_single = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
    out = run!(mtg_single, m_singlescale, df, orchestrator=orch2)


 ###########################
# Three timestep model that is single-scale, to circumvent refvector/refvalue overwriting
# and explore alternatives
# (eg filtering out timestep-mapped variables from vars_need_init and storing the values elsewhere)
# Not plugged in together atm, the variable mapping doesn't work
###########################

 m_singlescale = Dict("Default" => (
    MyToyDay2Model(),
    MyToyWeek2Model(),    
    MyToyFourWeek2Model(),    
    ),)


    model_timesteps_defaultscale = Dict(MyToyWeek2Model =>Week(1), MyToyFourWeek2Model =>Week(4), )
    to_w = PlantSimEngine.Var_to(:in_week)
    from_d = PlantSimEngine.Var_from(MyToyDay2Model, "Default", :out_day, sum)
    dict_to_from_w = Dict(from_d => to_w)

    to_w4_d = PlantSimEngine.Var_to(:in_four_week_from_day)
    to_w4_w = PlantSimEngine.Var_to(:in_four_week_from_week)
    from_w = PlantSimEngine.Var_from(MyToyWeek2Model, "Default", :out_week, sum)

    dict_to_from_w4 = Dict(from_d => to_w4_d, from_w => to_w4_w)
    
    mtsm_w = PlantSimEngine.ModelTimestepMapping(MyToyWeek2Model, "Default", Week(1), dict_to_from_w)
    mtsm_w4 = PlantSimEngine.ModelTimestepMapping(MyToyFourWeek2Model, "Default", Week(4), dict_to_from_w4)

    orch2 = PlantSimEngine.Orchestrator2(Day(1), [mtsm_w, mtsm_w4])

mtg_single = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
out = @run run!(mtg_single, m_singlescale, df, orchestrator=orch2)


###########################
# Test with three timesteps, multiscale + previoustimestep
###########################

# note the daily models don't specify a timestep range
# if you copy-paste this elsewhere, bear in mind that you might need to specify it

using MultiScaleTreeGraph
using PlantSimEngine
using PlantMeteo
using PlantMeteo.Dates

PlantSimEngine.@process "ToyDay2" verbose = false

struct MyToyDay2Model <: AbstractToyday2Model end

PlantSimEngine.inputs_(m::MyToyDay2Model) = NamedTuple()
PlantSimEngine.outputs_(m::MyToyDay2Model) = (out_day=-Inf,)

function PlantSimEngine.run!(m::MyToyDay2Model, models, status, meteo, constants=nothing, extra=nothing)
    status.out_day = meteo.data
end

#=PlantSimEngine.@process "ToyDay3" verbose = false

struct MyToyDay3Model <: AbstractToyday3Model end

PlantSimEngine.inputs_(m::MyToyDay3Model) = (in_day=-Inf, in_day_summed_prev_timestep=-Inf)
PlantSimEngine.outputs_(m::MyToyDay3Model) = (out_day_summed=-Inf,)

function PlantSimEngine.run!(m::MyToyDay3Model, models, status, meteo, constants=nothing, extra=nothing)
    status.out_day_summed = status.in_day + status.in_day_summed_prev_timestep
end

PlantSimEngine.@process "ToyDay4" verbose = false

struct MyToyDay4Model <: AbstractToyday4Model end

PlantSimEngine.inputs_(m::MyToyDay4Model) = (in_day_summed=-Inf,)
PlantSimEngine.outputs_(m::MyToyDay4Model) = (out_day_summed_2= -Inf,)

function PlantSimEngine.run!(m::MyToyDay4Model, models, status, meteo, constants=nothing, extra=nothing)
    status.out_day_summed_2 = status.in_day_summed
end=#

PlantSimEngine.@process "ToyWeek2" verbose = false

struct MyToyWeek2Model <: AbstractToyweek2Model end

PlantSimEngine.inputs_(::MyToyWeek2Model) = (in_week=-Inf,)
PlantSimEngine.outputs_(m::MyToyWeek2Model) = (out_week=-Inf,)

function PlantSimEngine.run!(m::MyToyWeek2Model, models, status, meteo, constants=nothing, extra=nothing)
    status.out_week = status.in_week 
end

PlantSimEngine.timestep_range_(m::MyToyWeek2Model) = TimestepRange(Week(1))

PlantSimEngine.@process "ToyPreviousWeek2" verbose = false

struct MyToyPreviousWeek2Model <: AbstractToypreviousweek2Model end

# TODO initialisation issue
PlantSimEngine.inputs_(::MyToyPreviousWeek2Model) = (in_last_week=-Inf,)
PlantSimEngine.outputs_(m::MyToyPreviousWeek2Model) = (out_last_week=-Inf,)

function PlantSimEngine.run!(m::MyToyPreviousWeek2Model, models, status, meteo, constants=nothing, extra=nothing)
    status.out_last_week += status.in_last_week/7.0 
end

PlantSimEngine.timestep_range_(m::MyToyPreviousWeek2Model) = TimestepRange(Week(1))


PlantSimEngine.@process "ToyFourWeek2" verbose = false

struct MyToyFourWeek2Model <: AbstractToyfourweek2Model end

PlantSimEngine.inputs_(::MyToyFourWeek2Model) = (in_four_week_from_week=-Inf, in_four_week_from_day=-Inf,)
PlantSimEngine.outputs_(m::MyToyFourWeek2Model) = (inputs_agreement=false,)

function PlantSimEngine.run!(m::MyToyFourWeek2Model, models, status, meteo, constants=nothing, extra=nothing)
    status.inputs_agreement = status.in_four_week_from_week == status.in_four_week_from_day
end

PlantSimEngine.timestep_range_(m::MyToyFourWeek2Model) = TimestepRange(Week(4))



df = DataFrame(:data => [1 for i in 1:365], )

    # TODO can make this optional if the timestep range is actually a single value
    model_timesteps_defaultscale = Dict(MyToyWeek2Model =>Week(1), MyToyFourWeek2Model =>Week(4), )

    to_w = PlantSimEngine.Var_to(:in_week)
    from_d = PlantSimEngine.Var_from(MyToyDay2Model, "Default", :out_day, sum)
    dict_to_from_w = Dict(from_d => to_w)

    to_w4_d = PlantSimEngine.Var_to(:in_four_week_from_day)
    to_w4_w = PlantSimEngine.Var_to(:in_four_week_from_week)
    from_w = PlantSimEngine.Var_from(MyToyWeek2Model, "Default2", :out_week, sum)

    dict_to_from_w4 = Dict(from_d => to_w4_d, from_w => to_w4_w)
    
    mtsm_w = PlantSimEngine.ModelTimestepMapping(MyToyWeek2Model, "Default2", Week(1), dict_to_from_w)
    mtsm_w4 = PlantSimEngine.ModelTimestepMapping(MyToyFourWeek2Model, "Default3", Week(4), dict_to_from_w4)

    orch2 = PlantSimEngine.Orchestrator2(Day(1), [mtsm_w, mtsm_w4])


m_multiscale = Dict(
"Default6" =>
    (
        MultiScaleModel(model=MyToyPreviousWeek2Model(),    
    mapped_variables=[PlantSimEngine.PreviousTimeStep(:in_last_week) => "Default2" => :out_week],
    ),
    Status(in_last_week=0.0, out_last_week=0.0)
    ),    
"Default" => (
    MyToyDay2Model(),
    ),
    "Default2" => (
    MultiScaleModel(model=MyToyWeek2Model(),    
    mapped_variables=[:in_week => "Default" => :out_day],
    ),
    ),
    #="Default3" => (
    MultiScaleModel(model=MyToyFourWeek2Model(),    
    mapped_variables=[
        :in_four_week_from_day => "Default" => :out_day,
        :in_four_week_from_week => "Default2" => :out_week,
        ],
    ),),
    "Default4"=> (
    MultiScaleModel(
        model=MyToyDay3Model(),
        mapped_variables=[
            PlantSimEngine.PreviousTimeStep(:in_day_summed_prev_timestep) => "Default5" => :out_day_summed_2,
            :in_day => "Default" => :out_day,
            ]),
            Status(in_day_summed_prev_timestep=0,)
    ),
    "Default5" => (
    MultiScaleModel(model=MyToyDay4Model(),
    mapped_variables= [:in_day_summed => "Default4" => :out_day_summed],
    ),
    Status(in_day_summed=0,out_day_summed_2=0)
    ),=#
    
    )

   
# TODO test with multiple nodes
mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 2))
#mtg3 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default3", 1, 3))
#mtg4 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default4", 1, 4))
#mtg5 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default5", 1, 5))
mtg6 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default6", 1, 6))

out = @run run!(mtg, m_multiscale, df, orchestrator=orch2)
out = run!(mtg, m_multiscale, df, orchestrator=orch2)

unique!([out["Default6"][i].out_last_week for i in 1:length(out["Default6"])])

# TODO : out_last_week is an output at the weekly scale, it isn't mapped
# Doesn't mesh well with current implementation : 
# non_default_timestep_mapping requires input + output, so the model and variable aren't declared
# I can infer the timestep from the timestep_range in this situation, but not for a model with a wider range
# This means the model needs to be declared somewhere






###########################
# Test with one timestep, multiscale + previoustimestep
###########################

# note the daily models don't specify a timestep range
# if you copy-paste this elsewhere, bear in mind that you might need to specify it

using MultiScaleTreeGraph
using PlantSimEngine
using PlantMeteo
using PlantMeteo.Dates

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

PlantSimEngine.timestep_range_(m::MyToyWeek2Model) = TimestepRange(Day(1))

PlantSimEngine.@process "ToyPreviousWeek2" verbose = false

struct MyToyPreviousWeek2Model <: AbstractToypreviousweek2Model end

# TODO initialisation issue
PlantSimEngine.inputs_(::MyToyPreviousWeek2Model) = (in_last_week=-Inf,)
PlantSimEngine.outputs_(m::MyToyPreviousWeek2Model) = (out_last_week=-Inf,)

function PlantSimEngine.run!(m::MyToyPreviousWeek2Model, models, status, meteo, constants=nothing, extra=nothing)
    status.out_last_week += status.in_last_week
end

PlantSimEngine.timestep_range_(m::MyToyPreviousWeek2Model) = TimestepRange(Day(1))


PlantSimEngine.@process "ToyFourWeek2" verbose = false

struct MyToyFourWeek2Model <: AbstractToyfourweek2Model end

PlantSimEngine.inputs_(::MyToyFourWeek2Model) = (in_four_week_from_week=-Inf, in_four_week_from_day=-Inf,)
PlantSimEngine.outputs_(m::MyToyFourWeek2Model) = (inputs_agreement=false,)

function PlantSimEngine.run!(m::MyToyFourWeek2Model, models, status, meteo, constants=nothing, extra=nothing)
    status.inputs_agreement = status.in_four_week_from_week == status.in_four_week_from_day
end

PlantSimEngine.timestep_range_(m::MyToyFourWeek2Model) = TimestepRange(Day(1))



df = DataFrame(:data => [1 for i in 1:365], )

    # TODO can make this optional if the timestep range is actually a single value
    #=model_timesteps_defaultscale = Dict(MyToyWeek2Model =>Week(1), MyToyFourWeek2Model =>Week(4), )

    to_w = PlantSimEngine.Var_to(:in_week)
    from_d = PlantSimEngine.Var_from(MyToyDay2Model, "Default", :out_day, sum)
    dict_to_from_w = Dict(from_d => to_w)

    to_w4_d = PlantSimEngine.Var_to(:in_four_week_from_day)
    to_w4_w = PlantSimEngine.Var_to(:in_four_week_from_week)
    from_w = PlantSimEngine.Var_from(MyToyWeek2Model, "Default2", :out_week, sum)

    dict_to_from_w4 = Dict(from_d => to_w4_d, from_w => to_w4_w)
    
    mtsm_w = PlantSimEngine.ModelTimestepMapping(MyToyWeek2Model, "Default2", Week(1), dict_to_from_w)
    mtsm_w4 = PlantSimEngine.ModelTimestepMapping(MyToyFourWeek2Model, "Default3", Week(4), dict_to_from_w4)

    orch2 = PlantSimEngine.Orchestrator2(Day(1), [mtsm_w, mtsm_w4])=#
orch2 = PlantSimEngine.Orchestrator2()

m_multiscale = Dict(
"Default6" =>
    (
        MultiScaleModel(model=MyToyPreviousWeek2Model(),    
    mapped_variables=[PlantSimEngine.PreviousTimeStep(:in_last_week) => "Default2" => :out_week],
    ),
    Status(in_last_week=0.0, out_last_week=0.0)
    ),    
"Default" => (
    MyToyDay2Model(),
    ),
    "Default2" => (
    MultiScaleModel(model=MyToyWeek2Model(),    
    mapped_variables=[:in_week => "Default" => :out_day],
    ),
    ),
    
    )

   
# TODO test with multiple nodes
mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 2))
mtg6 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default6", 1, 6))

out = @run run!(mtg, m_multiscale, df, orchestrator=orch2)
out = run!(mtg, m_multiscale, df, orchestrator=orch2)

unique!([out["Default6"][i].out_last_week for i in 1:length(out["Default6"])])



###########################
# Previous timestep debugging, not useful for testing timestep mapping atm
###########################
#=
using MultiScaleTreeGraph
using PlantSimEngine
using PlantMeteo
using PlantMeteo.Dates

PlantSimEngine.@process "current_timestep" verbose = false

struct HelperCurrentTimestepModel <: AbstractCurrent_TimestepModel
end

PlantSimEngine.inputs_(::HelperCurrentTimestepModel) = (next_timestep=1,)
PlantSimEngine.outputs_(m::HelperCurrentTimestepModel) = (current_timestep=1,)

function PlantSimEngine.run!(m::HelperCurrentTimestepModel, models, status, meteo, constants=nothing, extra=nothing)
    status.current_timestep = status.next_timestep
 end 

 PlantSimEngine.@process "next_timestep" verbose = false
 struct HelperNextTimestepModel <: AbstractNext_TimestepModel
 end
 
 PlantSimEngine.inputs_(::HelperNextTimestepModel) = (current_timestep=1,)
 PlantSimEngine.outputs_(m::HelperNextTimestepModel) = (next_timestep=1,)
 
 function PlantSimEngine.run!(m::HelperNextTimestepModel, models, status, meteo, constants=nothing, extra=nothing)
     status.next_timestep = status.current_timestep + 1
  end 

  df = DataFrame(:data => [1 for i in 1:365], )

  m_ms = Dict(
  "B" => (
                    MultiScaleModel(
                    model=HelperCurrentTimestepModel(),
                    mapped_variables=[PreviousTimeStep(:next_timestep),],
                    ),        
        Status(next_timestep=2)

    ),
     "A" => (
                    HelperNextTimestepModel(),
                    Status(current_timestep=1)
  ),
  )

m_ss = Dict(
    "A" => (
        HelperNextTimestepModel(),
        MultiScaleModel(
            model=HelperCurrentTimestepModel(),
            mapped_variables=[PreviousTimeStep(:next_timestep),],
        ),
        Status(current_timestep=1, next_timestep=1)),
)

  mtg_ = Node(MultiScaleTreeGraph.NodeMTG("/", "A", 1, 1))
#mtg2 = Node(mtg_, MultiScaleTreeGraph.NodeMTG("/", "B", 1, 2))
out = @run run!(mtg_, m_ss, df)
=#

###########################
# Test with a D -> W -> D configuration, with multiple variables mapped between timesteps
###########################

# Currently, weekly_max_temperature will raise an error : 
# It is mapped correctly, timestep-mapped correctly, but not detected as an output at its scale
# Since it doesn't appear explicitely as the output of a model
# Setting it as the output would cause issues in status creation and refs, as well as during mapping

using MultiScaleTreeGraph
using PlantSimEngine
using PlantMeteo
using PlantMeteo.Dates

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
PlantSimEngine.outputs_(m::MyToyWeekDWDModel) = (hot = false, sum=-Inf)

function PlantSimEngine.run!(m::MyToyWeekDWDModel, models, status, meteo, constants=nothing, extra=nothing)
    status.hot = status.weekly_max_temperature > m.temperature_threshold
    status.sum += status.weekly_sum_temperature
end

PlantSimEngine.timestep_range_(m::MyToyWeekDWDModel) = TimestepRange(Week(1))

PlantSimEngine.@process "ToyDayDWDOut" verbose = false

struct MyToyDayDWDOutModel <: AbstractToydaydwdoutModel end

PlantSimEngine.inputs_(m::MyToyDayDWDOutModel) = (weekly_max_temperature=-Inf,weekly_sum_temperature=-Inf,)
PlantSimEngine.outputs_(m::MyToyDayDWDOutModel) = (out=-Inf,)

function PlantSimEngine.run!(m::MyToyDayDWDOutModel, models, status, meteo, constants=nothing, extra=nothing)
    status.out = status.weekly_sum_temperature - 7.0*meteo.data
end

df = DataFrame(:data => [1 for i in 1:365], )

m_dwd = Dict("Default" => (
    MyToyDayDWDModel(),
    MultiScaleModel(
    model=MyToyDayDWDOutModel(),
    mapped_variables=[:weekly_max_temperature => "Default2", :weekly_sum_temperature => "Default2"]
    ),
    Status(a=1,out=0.0)
    ),
    "Default2" => (
    MultiScaleModel(model=MyToyWeekDWDModel(),    
    #mapped_variables=[:weekly_max_temperature => ["Default" => :daily_temperature]], # TODO test this
    mapped_variables=[:weekly_max_temperature => "Default" => :daily_temperature, :weekly_sum_temperature => "Default" => :daily_temperature],
    ),
    Status(weekly_max_temperature=0.0, weekly_sum_temperature=0.0, sum=0.0)
    ),
)


mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 2))

to = PlantSimEngine.Var_to(:weekly_max_temperature)
from = PlantSimEngine.Var_from(MyToyDayDWDModel, "Default", :daily_temperature, maximum)

to_sum = PlantSimEngine.Var_to(:weekly_sum_temperature)
from_sum = PlantSimEngine.Var_from(MyToyDayDWDModel, "Default", :daily_temperature, sum)

dict_to_from = Dict(from => to, from_sum => to_sum)
mtsm_dwd = PlantSimEngine.ModelTimestepMapping(MyToyWeekDWDModel, "Default2", Week(1), dict_to_from)

#dict_to_from_2 = Dict(from => to, from => to)
#mtsm2 = PlantSimEngine.ModelTimestepMapping(MyToyDayDWDOutModel, "Default", Day(1), dict_to_from2)

orch_dwd = PlantSimEngine.Orchestrator2(Day(1), [mtsm_dwd,])#mtsm2])

out = run!(mtg, m_dwd, df, orchestrator=orch_dwd)


##################################
# Two variables mapped
##################################

using MultiScaleTreeGraph
using PlantSimEngine
using PlantMeteo
using PlantMeteo.Dates

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
PlantSimEngine.outputs_(m::MyToyWeekDWDModel) = (hot = false, sum=-Inf)

function PlantSimEngine.run!(m::MyToyWeekDWDModel, models, status, meteo, constants=nothing, extra=nothing)
    status.hot = status.weekly_max_temperature > m.temperature_threshold
    status.sum += status.weekly_sum_temperature
end

PlantSimEngine.timestep_range_(m::MyToyWeekDWDModel) = TimestepRange(Week(1))

#df = DataFrame(:data => [1 for i in 1:365], )
meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)

m_dwd = Dict("Default" => (
    MyToyDayDWDModel(),
    Status(a=1,)
    ),
    "Default2" => (
    MultiScaleModel(model=MyToyWeekDWDModel(),    
    #mapped_variables=[:weekly_max_temperature => ["Default" => :daily_temperature]], # TODO test this
    mapped_variables=[:weekly_max_temperature => "Default" => :daily_temperature, :weekly_sum_temperature => "Default" => :daily_temperature],
    ),
    Status(weekly_max_temperature=0.0, weekly_sum_temperature=0.0, sum =0.0)
    ),
)


mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 2))

to = PlantSimEngine.Var_to(:weekly_max_temperature)
from = PlantSimEngine.Var_from(MyToyDayDWDModel, "Default", :daily_temperature, maximum)

to_sum = PlantSimEngine.Var_to(:weekly_sum_temperature)
from_sum = PlantSimEngine.Var_from(MyToyDayDWDModel, "Default", :daily_temperature, sum)

dict_to_from = Dict(from => to, from_sum => to_sum)
mtsm_dwd = PlantSimEngine.ModelTimestepMapping(MyToyWeekDWDModel, "Default2", Week(1), dict_to_from)

orch_dwd = PlantSimEngine.Orchestrator2(Day(1), [mtsm_dwd,])

out = run!(mtg, m_dwd, meteo_day, orchestrator=orch_dwd)



##########################
# Two models, D -> W, but D has two MTG nodes
# So simple test of a RefVector + timestep mapping combo
##########################

# Currently errors due to refvectors not being handled properly

using MultiScaleTreeGraph
using PlantSimEngine
using PlantMeteo
using PlantMeteo.Dates

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
PlantSimEngine.outputs_(m::MyToyWeekModel) = (hot = false,)

function PlantSimEngine.run!(m::MyToyWeekModel, models, status, meteo, constants=nothing, extra=nothing)
    status.hot = status.weekly_max_temperature > m.temperature_threshold
end

PlantSimEngine.timestep_range_(m::MyToyWeekModel) = TimestepRange(Week(1))


meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)

m_multiscale = Dict("Default" => (
    MyToyDayModel(),
    Status(a=1,)
    ),
    "Default2" => (
    MultiScaleModel(model=MyToyWeekModel(),    
    mapped_variables=[:weekly_max_temperature => ["Default" => :daily_temperature]], # TODO test this
    #mapped_variables=[:weekly_max_temperature => "Default" => :daily_temperature],
    ),
    ),)


mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Default", 1, 1))
mtg3 = Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Default2", 1, 2))

to = PlantSimEngine.Var_to(:weekly_max_temperature)
from = PlantSimEngine.Var_from(MyToyDayModel, "Default", :daily_temperature, maximum)

dict_to_from = Dict(from => to)
mtsm = PlantSimEngine.ModelTimestepMapping(MyToyWeekModel, "Default2", Week(1), dict_to_from)

#orch2 = PlantSimEngine.Orchestrator2(Day(1), [mtsm,])
orch2 = PlantSimEngine.Orchestrator2()
out = run!(mtg, m_multiscale, meteo_day, orchestrator=orch2)
#out = run!(mtg, m_multiscale, meteo_day, orchestrator=orch2)



# alternate mtg with 2 nodes -> 2 nodes
#mtg_bis = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
#mtg_bis_1 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
#mtg_bis_2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Default2", 1, 2))
#mtg_bis_3 = Node(mtg, MultiScaleTreeGraph.NodeMTG("+", "Default2", 1, 2))
#out = @enter run!(mtg_bis, m_multiscale, meteo_day, orchestrator=orch2)
