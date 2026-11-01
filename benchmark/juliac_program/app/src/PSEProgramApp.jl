module PSEProgramApp
include("program.jl")
include("fixture.jl")
include("xpalm_fixture.jl")

const XPALM_PROGRAM = ReusableProgram.prepare(XPalmFixture.specs();initial=XPalmFixture.initial())

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

function (@main)(args::Vector{String})
    length(args) == 9 || throw(ArgumentError("expected mode plus eight numeric inputs"))
    mode = args[1]
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
