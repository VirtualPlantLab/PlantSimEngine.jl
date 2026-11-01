module ProgramScreen
using Dates
using Statistics
using PlantSimEngine
import ..ReusableProgram as RP
import ..NativeFixture as NF

function _weather(rows)
    Weather([Atmosphere(date=DateTime(2025,1,1)+Day(i-1), T=row.T,
        Wind=1.0, Rh=0.5, P=100.0, Ri_SW_f=100.0, duration=Day(1))
        for (i,row) in enumerate(rows)])
end
function _scene(ids, specs, weather)
    CompositeModel((Object(id; kind=:leaf) for id in ids)...;
        applications=specs, environment=weather)
end
function _execute!(state, rows)
    for row in rows
        RP.step!(state, row)
    end
    return state
end
# Same original scientific methods, same status schema, same region-major order.
# This reference omits validation/scheduling and is not a complete PSE substitute.
function _hand!(statuses, models, rows)
    for row in rows
        for status in statuses
            PlantSimEngine.run!(models[2], status, row, nothing, nothing)
        end
        for status in statuses
            PlantSimEngine.run!(models[1], status, row, nothing, nothing)
        end
    end
    return statuses
end
_digest(statuses) = map(s -> (s.carbon,s.leaf_area,s.biomass), statuses)

function screen(n::Int=32, steps::Int=128; cycles::Int=4)
    specs = NF.specs()
    models = map(s -> s.model, specs)
    program_preparation = @timed RP.prepare(specs)
    program = program_preparation.value # once, outside amortized runs
    ids = collect(1:n)
    kinds = fill(:leaf,n)
    rows = [(T=20.0+mod(i,7),) for i in 1:steps]
    weather = _weather(rows) # common forcing construction excluded for all arms
    native_samples = NamedTuple[]
    ordinary_samples = NamedTuple[]
    hand_samples = NamedTuple[]
    # First iteration warms every exact case; subsequent cycles alternate order.
    for cycle in 0:cycles
        for arm in (iseven(cycle) ? (:ordinary,:native,:hand) : (:hand,:native,:ordinary))
            GC.gc()
            if arm === :ordinary
                construction = @timed _scene(ids,specs,weather)
                preparation = @timed run!(construction.value; steps=0, outputs=:none)
                execution = @timed continue!(preparation.value; steps)
                observed = [(final_state(execution.value,ObjectId(id)).carbon,
                    final_state(execution.value,ObjectId(id)).leaf_area,
                    final_state(execution.value,ObjectId(id)).biomass) for id in ids]
                expected = _digest(_hand!([Status((carbon=0.0,leaf_area=1.0,biomass=0.0)) for _ in ids],models,rows))
                @assert observed == expected
                cycle == 0 || push!(ordinary_samples,(preparation_s=construction.time+preparation.time,
                    execution_s=execution.time, total_s=construction.time+preparation.time+execution.time,
                    preparation_bytes=construction.bytes+preparation.bytes,execution_bytes=execution.bytes))
            elseif arm === :native
                preparation = @timed RP.instantiate(program,models,ids,kinds)
                execution = @timed _execute!(preparation.value,rows)
                expected = _digest(_hand!([Status((carbon=0.0,leaf_area=1.0,biomass=0.0)) for _ in ids],models,rows))
                @assert _digest(execution.value.statuses) == expected
                cycle == 0 || push!(native_samples,(preparation_s=preparation.time,
                    execution_s=execution.time,total_s=preparation.time+execution.time,
                    preparation_bytes=preparation.bytes,execution_bytes=execution.bytes))
            else
                preparation = @timed [Status((carbon=0.0,leaf_area=1.0,biomass=0.0)) for _ in ids]
                execution = @timed _hand!(preparation.value,models,rows)
                cycle == 0 || push!(hand_samples,(preparation_s=preparation.time,
                    execution_s=execution.time,total_s=preparation.time+execution.time,
                    preparation_bytes=preparation.bytes,execution_bytes=execution.bytes))
            end
        end
    end
    summarize(samples) = (; (name=>median(getproperty.(samples,name)) for name in keys(first(samples)))...)
    return (n,steps,cycles,program_preparation_s=program_preparation.time,ordinary=summarize(ordinary_samples),
        program=summarize(native_samples),hand=summarize(hand_samples),
        samples=(ordinary=ordinary_samples,program=native_samples,hand=hand_samples))
end
function allocation_gate()
    specs = NF.specs()
    program = RP.prepare(specs)
    state = RP.instantiate(program,map(s -> s.model,specs),collect(1:32),fill(:leaf,32))
    rows = [(T=20.0,) for _ in 1:128]
    _execute!(state,rows)
    bytes = [@allocated(_execute!(state,rows)) for _ in 1:5]
    @assert all(iszero,bytes)
    return bytes
end

end
