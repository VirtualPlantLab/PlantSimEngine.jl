
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


###########################
# First attempt at an orchetrator, broken by subsequent changes
###########################
#=
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
     (weekly_max_temperature=-Inf,)
end
PlantSimEngine.outputs_(m::MyToyWeekModel) = (hot = false,)

function PlantSimEngine.run!(m::MyToyWeekModel, models, status, meteo, constants=nothing, extra=nothing)
    status.hot = status.weekly_max_temperature > m.temperature_threshold
end

PlantSimEngine.timestep_range_(m::MyToyWeekModel) = TimestepRange(Week(1))


m = Dict("Default" => (
    MyToyDayModel(), 
    MyToyWeekModel(),    
    Status(a=1,)))
   
    meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)
mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))


    model_timesteps_defaultscale = Dict(MyToyWeekModel =>Week(1))
    tsm = PlantSimEngine.TimestepMapper(:daily_temperature, Day(1), max, nothing)
    sth = PlantSimEngine.SimulationTimestepHandler(model_timesteps_defaultscale, Dict(:weekly_max_temperature => tsm ))

    orchestrator = Orchestrator(Day(1), Dict("Default" => sth))

    #out = @enter run!(mtg, m, meteo_day, orchestrator=orchestrator)

# TODO could some mapping happen automatically for variables directly taken from weather data ?
# Does this happen often in a typical model ?

#=m_multiscale = Dict("Default" => (
    MyToyDayModel(),
    Status(a=1,)
    ),
    "Default2" => (
    MyToyWeekModel(),    
    ),)
=#
m_multiscale = Dict("Default" => (
    MyToyDayModel(),
    Status(a=1,)
    ),
    "Default2" => (
    MultiScaleModel(model=MyToyWeekModel(),    
    mapped_variables=[:weekly_max_temperature => "Default" => :daily_temperature],
    ),
    ),)



mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 2))

 orchestrator_multiscale = Orchestrator(Day(1), Dict("Default2" => sth))

#out = @enter run!(mtg, m_multiscale, meteo_day, orchestrator=orchestrator_multiscale)
=#


###########################
# Simple test with a second attempt at an orchestrator
# Functional, except for the revalue/refvector overwriting issues
###########################
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
     (weekly_max_temperature=-Inf,)
end
PlantSimEngine.outputs_(m::MyToyWeekModel) = (hot = false,)

function PlantSimEngine.run!(m::MyToyWeekModel, models, status, meteo, constants=nothing, extra=nothing)
    status.hot = status.weekly_max_temperature > m.temperature_threshold
end

PlantSimEngine.timestep_range_(m::MyToyWeekModel) = TimestepRange(Week(1))


    meteo_day = read_weather(joinpath(pkgdir(PlantSimEngine), "examples/meteo_day.csv"), duration=Day)

    model_timesteps_defaultscale = Dict(MyToyWeekModel =>Week(1))
    tsm = PlantSimEngine.TimestepMapper(:daily_temperature, Day(1), max, nothing)
    sth = PlantSimEngine.SimulationTimestepHandler(model_timesteps_defaultscale, Dict(:weekly_max_temperature => tsm ))

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

dict_to_from = Dict(to => from)
mtsm = PlantSimEngine.ModelTimestepMapping(MyToyWeekModel, "Default2", Week(1), dict_to_from)

orch2 = PlantSimEngine.Orchestrator2(Day(1), [mtsm,])

out = @enter run!(mtg, m_multiscale, meteo_day, orchestrator=orch2)
 

###########################
# Test with three timesteps, multiscale
# Issues with data overwriting (refvector/refvalue)
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
    tsm_d = PlantSimEngine.TimestepMapper(:out_day, Day(1), sum, nothing)
    sth_d = PlantSimEngine.SimulationTimestepHandler(model_timesteps_defaultscale, Dict(:in_week => tsm_d ))

    tsm_w = PlantSimEngine.TimestepMapper(:out_week, Week(1), sum, nothing)
    sth_w = PlantSimEngine.SimulationTimestepHandler(model_timesteps_defaultscale, Dict(:in_four_week_from_day => tsm_d, :in_four_week_from_week => tsm_w ))

    to_w = PlantSimEngine.Var_to(:in_week)
    from_d = PlantSimEngine.Var_from(MyToyDay2Model, "Default", :out_day, sum)
    dict_to_from_w = Dict(to_w => from_d)

    to_w4_d = PlantSimEngine.Var_to(:in_four_week_from_day)
    to_w4_w = PlantSimEngine.Var_to(:in_four_week_from_week)
    from_w = PlantSimEngine.Var_from(MyToyWeek2Model, "Default2", :out_week, sum)

    dict_to_from_w4 = Dict(to_w4_d => from_d, to_w4_w => from_w)
    
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
    ),
    ),)

   
# TODO test with multiple nodes
mtg = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
mtg2 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default2", 1, 2))
mtg3 = Node(mtg, MultiScaleTreeGraph.NodeMTG("/", "Default3", 1, 3))
#out = @enter run!(mtg, m_multiscale, df, orchestrator=orch2)



###########################
# Three timestep model that is single-scale, to circumvent refvector/refvalue overwriting
# and explore alternatives
# (eg filtering out timestep-mapped variables from vars_need_init and storing the values elsewhere)
###########################

 m_singlescale = Dict("Default" => (
    MyToyDay2Model(),
    MyToyWeek2Model(),    
    MyToyFourWeek2Model(),    
    ),)


    model_timesteps_defaultscale = Dict(MyToyWeek2Model =>Week(1), MyToyFourWeek2Model =>Week(4), )
    tsm_d = PlantSimEngine.TimestepMapper(:out_day, Day(1), sum, nothing)
    sth_d = PlantSimEngine.SimulationTimestepHandler(model_timesteps_defaultscale, Dict(:in_week => tsm_d ))

    tsm_w = PlantSimEngine.TimestepMapper(:out_week, Week(1), sum, nothing)
    sth_w = PlantSimEngine.SimulationTimestepHandler(model_timesteps_defaultscale, Dict(:in_four_week_from_day => tsm_d, :in_four_week_from_week => tsm_w ))

    to_w = PlantSimEngine.Var_to(:in_week)
    from_d = PlantSimEngine.Var_from(MyToyDay2Model, "Default", :out_day, sum)
    dict_to_from_w = Dict(to_w => from_d)

    to_w4_d = PlantSimEngine.Var_to(:in_four_week_from_day)
    to_w4_w = PlantSimEngine.Var_to(:in_four_week_from_week)
    from_w = PlantSimEngine.Var_from(MyToyWeek2Model, "Default", :out_week, sum)

    dict_to_from_w4 = Dict(to_w4_d => from_d, to_w4_w => from_w)
    
    mtsm_w = PlantSimEngine.ModelTimestepMapping(MyToyWeek2Model, "Default", Week(1), dict_to_from_w)
    mtsm_w4 = PlantSimEngine.ModelTimestepMapping(MyToyFourWeek2Model, "Default", Week(4), dict_to_from_w4)

    orch2 = PlantSimEngine.Orchestrator2(Day(1), [mtsm_w, mtsm_w4])

mtg_single = Node(MultiScaleTreeGraph.NodeMTG("/", "Default", 1, 1))
out = @run run!(mtg_single, m_singlescale, df, orchestrator=orch2)



using Test
 @test unique([out["Default3"][i].in_four_week_from_day for i in 1:length(out["Default3"])]) == [0.0, 28.0]
 @test unique([out["Default3"][i].in_four_week_from_week for i in 1:length(out["Default3"])]) == [0.0, 7.0]
 @test unique([out["Default3"][i].inputs_agreement for i in 1:length(out["Default3"])]) == [1]

 unique([out["Default3"][i].in_four_week_from_week for i in 1:length(out["Default3"])])
 unique([out["Default3"][i].in_four_week_from_day for i in 1:length(out["Default3"])])
 unique([out["Default3"][i].inputs_agreement for i in 1:length(out["Default3"])])