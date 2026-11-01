module PSEProgramApp
include("program.jl")
include("fixture.jl")

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

function (@main)(args::Vector{String})
    length(args) == 8 || throw(ArgumentError("expected population steps birth_at newborns id_offset efficiency conversion temperature"))
    result = simulate(parse(Int, args[1]), parse(Int, args[2]), parse(Int, args[3]),
        parse(Int, args[4]), parse(Int, args[5]), parse(Float64, args[6]),
        parse(Float64, args[7]), parse(Float64, args[8]))
    # Keep tabular formatting, Term and introspection outside the native entry.
    println(Core.stdout, result[1], ',', result[2], ',', result[3], ',', result[4])
    return 0
end
end
