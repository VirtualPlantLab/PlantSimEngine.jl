module PSEProgramApp
include("program.jl")
include("fixture.jl")
include("xpalm_fixture.jl")
include("phytomer_fixture.jl")

const XPALM_PROGRAM = ReusableProgram.prepare(XPalmFixture.specs();initial=XPalmFixture.initial())

const GROWTH_MODELS = PhytomerFixture.models(PhytomerFixture.tree())
const GROWTH_PROGRAM = ReusableProgram.prepare(PhytomerFixture.specs(PhytomerFixture.tree());initial=PhytomerFixture.initial())

const PROGRAM = ReusableProgram.prepare(NativeFixture.specs())

# The entry's input schema is fixed. Counts, IDs, parameters and duration are data.
function simulate(population::Int, steps::Int, birth_at::Int, newborns::Int,
                  id_offset::Int, efficiency::Float64, conversion::Float64, temperature::Float64)
    population >= 0 && steps >= 0 && newborns >= 0 || throw(ArgumentError("negative count"))
    (birth_at != 0 || newborns == 0) || throw(ArgumentError("birth_at=0 requires newborns=0"))
    0 <= birth_at <= steps || throw(ArgumentError("birth timestep out of range"))
    models = (NativeFixture.Accumulation(conversion), NativeFixture.Assimilation(efficiency))
    state = ReusableProgram.instantiate(PROGRAM, models,
        collect((id_offset + 1):(id_offset + population)), fill(:leaf, population))
    for i in 1:steps
        if i == birth_at
            for j in 1:newborns
                ReusableProgram.add_object!(state, id_offset + population + j, :leaf)
            end
        end
        ReusableProgram.step!(state, (T=temperature + i,))
    end
    carbon = 0.0
    biomass = 0.0
    for status in state.statuses
        carbon += status.carbon
        biomass += status.biomass
    end
    return (length(state.ids), state.step, carbon, biomass)
end

function simulate_xpalm(population::Int, steps::Int, birth_at::Int, newborns::Int,
                        id_offset::Int, initial_depth::Float64, root_rate::Float64, rain::Float64)
    population >= 0 && steps >= 0 && newborns >= 0 || throw(ArgumentError("negative count"))
    (birth_at != 0 || newborns == 0) || throw(ArgumentError("birth_at=0 requires newborns=0"))
    0 <= birth_at <= steps || throw(ArgumentError("birth timestep out of range"))
    models = XPalmFixture.models(;initial_depth,root_rate)
    state = ReusableProgram.instantiate(XPALM_PROGRAM,models,
        collect((id_offset+1):(id_offset+population)),fill(:soil,population);
        initial=XPalmFixture.initial())
    constants = XPalmFixture.PSE.Constants()
    for (i,environment) in enumerate(XPalmFixture.rows(steps;rain))
        if i == birth_at
            for j in 1:newborns
                ReusableProgram.add_object!(state,id_offset+population+j,:soil)
            end
        end
        ReusableProgram.step!(state,environment;constants)
    end
    return state
end

# Release defaults are loaded at authoring/build time. Runtime parameters replace
# immutable model values without invoking YAML loading or ModelSpec construction.
function simulate_phytomers(days::Int,rate::Float64,biomass::Float64,Tmin::Float64,Tmax::Float64,age::Int)
    days>=0 && rate>=0 && biomass>=0 || throw(ArgumentError("negative growth input"))
    t=GROWTH_MODELS
    models=(t[1],PhytomerFixture.Models.DailyPlantAgeModel(age),
        PhytomerFixture.Models.PhyllochronModel(t[3].age_palm_maturity,rate,rate),
        t[4],t[5],t[6],t[7],t[8],t[9],t[10],t[11])
    state=ReusableProgram.instantiate(GROWTH_PROGRAM,models,PhytomerFixture.tree();
        initial=PhytomerFixture.initial(;biomass,initiation_age=age))
    constants=XPalmFixture.PSE.Constants()
    for row in PhytomerFixture.rows(days;Tmin,Tmax)
        ReusableProgram.step!(state,row;constants)
    end
    return state
end
_print_growth_value(value)=print(Core.stdout,value)
_print_growth_value(value::XPalmFixture.PSE.ObjectId)=print(Core.stdout,value.value)
_print_growth_values(::Tuple{})=nothing
function _print_growth_values(values::Tuple)
    print(Core.stdout,','); _print_growth_value(first(values))
    _print_growth_values(Base.tail(values))
end
_print_growth_cohorts(::Tuple{})=nothing
function _print_growth_cohorts(cohorts::Tuple)
    cohort=first(cohorts)
    for i in eachindex(cohort.ids)
        node=cohort.nodes[i]; parent=PhytomerFixture.MTG.parent(node)
        print(Core.stdout,ReusableProgram._cohort_key(cohort),',',cohort.ids[i],',',
            isnothing(parent) ? 0 : PhytomerFixture.MTG.node_id(parent),',',
            PhytomerFixture.MTG.link(node),',',PhytomerFixture.MTG.index(node))
        _print_growth_values(values(NamedTuple(cohort.rows[i])))
        println(Core.stdout)
    end
    _print_growth_cohorts(Base.tail(cohorts))
end

function (@main)(args::Vector{String})
    isempty(args) && throw(ArgumentError("expected mode"))
    mode = args[1]
    if mode=="phytomer"
        length(args)==7 || throw(ArgumentError("phytomer days rate biomass Tmin Tmax initiation_age"))
        state=simulate_phytomers(parse(Int,args[2]),parse(Float64,args[3]),parse(Float64,args[4]),
            parse(Float64,args[5]),parse(Float64,args[6]),parse(Int,args[7]))
        println(Core.stdout,length(state.nodes),',',state.step)
        _print_growth_cohorts(state.cohorts)
        return 0
    end
    length(args) == 9 || throw(ArgumentError("expected mode plus eight numeric inputs"))
    inputs = (parse(Int,args[2]),parse(Int,args[3]),parse(Int,args[4]),
        parse(Int,args[5]),parse(Int,args[6]),parse(Float64,args[7]),
        parse(Float64,args[8]),parse(Float64,args[9]))
    if mode == "fixture"
        result = simulate(inputs...)
        println(Core.stdout,result[1],',',result[2],',',result[3],',',result[4])
    elseif mode == "xpalm"
        state = simulate_xpalm(inputs...)
        println(Core.stdout,length(state.ids),',',state.step)
        for i in eachindex(state.ids)
            print(Core.stdout,state.ids[i])
            for variable in XPalmFixture.STATE_VARIABLES
                print(Core.stdout,',',state.statuses[i][variable])
            end
            println(Core.stdout)
        end
    else
        throw(ArgumentError("unknown mode"))
    end
    return 0
end
end
