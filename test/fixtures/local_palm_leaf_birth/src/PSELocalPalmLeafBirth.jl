module PSELocalPalmLeafBirth

include("native_preparation.jl")
include("fixture.jl")
include("prepare.jl")
using .LocalPalmLeafBirth
using .LocalPalmLeafBirthPreparation: prepare_native_scene
import PlantSimEngine as PSE
include("tree_birth.jl")

# A alone is the only retained payload. The native count is command-line data.
const STATE = prepare_native_scene()

pack(value::Float32) = UInt64(reinterpret(UInt32,value))
pack(value::Int64) = reinterpret(UInt64,value)

function append_history!(report,simulation,application,id,variable,::Type{T}) where {T}
    samples = PSE.outputs(simulation)[(application,PSE.ObjectId(id),variable)]::Vector{Tuple{Float64,T}}
    push!(report,UInt64(length(samples)))
    for (time,value) in samples
        push!(report,reinterpret(UInt64,time),pack(value))
    end
    return report
end

# Bounded binary output avoids IO formatting in the safe runtime. The same
# ordered A values and all 16 retained output series are compared by the host.
function a_report(state,requested)
    a = first(state.records)
    report = UInt64[0x50414c4d42495254,UInt64(requested),UInt64(length(state.records)),
        UInt64(length(PSE.runtime_model(state.simulation).registry.objects)),
        UInt64(PSE.current_step(state.simulation))]
    for value in values(palm_values(a.palm))
        push!(report,pack(value))
    end
    for leaf in (a.leaf[1],a.leaf[2],state.newborn)
        for value in values(leaf_values(leaf))
            push!(report,pack(value))
        end
    end
    append_history!(report,state.simulation,:palm_supply,Int64(1),:supply,Float32)
    append_history!(report,state.simulation,:palm_carbon,Int64(1),:carbon,Float32)
    append_history!(report,state.simulation,:palm_carbon,Int64(1),:reserve,Float32)
    append_history!(report,state.simulation,:palm_carbon,Int64(1),:leaf_count,Int64)
    for id in (Int64(2),Int64(3),Int64(4))
        append_history!(report,state.simulation,:leaf_assimilation,id,:assimilation,Float32)
        append_history!(report,state.simulation,:leaf_assimilation,id,:water_seen,Float32)
        append_history!(report,state.simulation,:leaf_assimilation,id,:previous_seen,Float32)
        append_history!(report,state.simulation,:leaf_assimilation,id,:visits,Int64)
    end
    return report
end

function write_report(words::Vector{UInt64},fd::Cint=Cint(1))
    byte_count = sizeof(UInt64)*length(words)
    written = GC.@preserve words ccall(:write,Clong,(Cint,Ptr{UInt8},Csize_t),
        fd,Ptr{UInt8}(pointer(words)),byte_count)
    return written == byte_count
end

# A separate bounded report retains every neighbour's final values and all
# twelve scientific output histories. No sample is discarded or averaged.
function neighbour_report(state,timings)
    report=UInt64[0x4e45494748424f52,UInt64(state.neighbours)]
    for r in state.records[2:end]
        push!(report,UInt64(r.id),UInt64(r.leaves[1]),UInt64(r.leaves[2]))
        for value in values(palm_values(r.palm))
            push!(report,pack(value))
        end
        for leaf in r.leaf, value in values(leaf_values(leaf))
            push!(report,pack(value))
        end
        append_history!(report,state.simulation,:palm_supply,r.id,:supply,Float32)
        append_history!(report,state.simulation,:palm_carbon,r.id,:carbon,Float32)
        append_history!(report,state.simulation,:palm_carbon,r.id,:reserve,Float32)
        append_history!(report,state.simulation,:palm_carbon,r.id,:leaf_count,Int64)
        for id in r.leaves
            append_history!(report,state.simulation,:leaf_assimilation,id,:assimilation,Float32)
            append_history!(report,state.simulation,:leaf_assimilation,id,:water_seen,Float32)
            append_history!(report,state.simulation,:leaf_assimilation,id,:previous_seen,Float32)
            append_history!(report,state.simulation,:leaf_assimilation,id,:visits,Int64)
        end
    end
    # The last six words are a tag plus five UInt64 nanosecond durations.
    push!(report,0x50484153454e5343)
    for elapsed in values(timings)
        push!(report,elapsed)
    end
    return report
end

function (@main)(args)
    length(args)==1 || return 2
    if only(args) == "tree"
        isnothing(TREE_BIRTH) && return 2
        return check_tree_birth!(TREE_BIRTH) ? 0 : 1
    end
    neighbours=parse(Int,args[1])
    neighbours in (0,100) || return 2
    result=native_run!(STATE,neighbours)
    result.ok || return 1
    write_report(a_report(result.state,neighbours)) || return 3
    return write_report(neighbour_report(result.state,result.timings),Cint(2)) ? 0 : 3
end

end
