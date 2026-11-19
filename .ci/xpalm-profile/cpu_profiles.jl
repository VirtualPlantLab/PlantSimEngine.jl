module MatchedCPUProfiles
using Profile
export initialize!, profile_steps!, summarize

function initialize!()
    Profile.init(; n=10_000_000, delay=0.0001)
    Profile.@profile nothing
    Profile.clear()
    return nothing
end

# The sample gate follows the frozen classification and every actual day checks it.
# Timers are stopped before all observations. :none is the ordinary warm loop.
Base.@constprop :none Base.@noinline function profile_steps!(step!, object_count, simulation,
    expected_counts, sample_mode::Symbol)
    @assert sample_mode in (:none, :ordinary, :growth)
    observed = Vector{NamedTuple{(:day, :before, :after, :growth, :sampled, :profile_words),
        Tuple{Int,Int,Int,Bool,Bool,Int}}}(undef, length(expected_counts) - 1)
    @assert object_count(simulation) == first(expected_counts)
    for day in eachindex(observed)
        before = object_count(simulation)
        expected_growth = expected_counts[day + 1] > expected_counts[day]
        sampled = sample_mode !== :none && (sample_mode === :growth) == expected_growth
        words_before = Profile.len_data()
        if sampled
            Profile.@profile step!(simulation)
        else
            step!(simulation)
        end
        words_after = Profile.len_data()
        after = object_count(simulation)
        growth = after > before
        @assert before == expected_counts[day] && after == expected_counts[day + 1]
        @assert growth == expected_growth
        @assert sampled == (sample_mode !== :none && (sample_mode === :growth) == growth)
        observed[day] = (; day, before, after, growth, sampled,
            profile_words=Int(words_after - words_before))
    end
    return observed
end

bounded(s, n) = first(String(s), min(length(String(s)), n))
function frame_key(frame)
    module_name = if frame.linfo isa Core.MethodInstance && frame.linfo.def isa Method
        string(frame.linfo.def.module)
    else
        frame.from_c ? "C" : "unknown"
    end
    file = String(frame.file)
    file = replace(file, r"^.*?/PlantSimEngine/" => "PlantSimEngine/")
    file = replace(file, r"^.*?/XPalm/" => "XPalm/")
    # Use only the bare symbol, file and line: never show a MethodInstance/type signature.
    return (bounded(module_name, 100), bounded(frame.func, 180), bounded(file, 260),
        Int(frame.line), frame.from_c)
end
frame_record(key) = (; module_name=key[1], function_name=key[2], file=key[3],
    line=key[4], from_c=key[5])
function summarize()
    full = Profile.is_buffer_full()
    data, dictionary = Profile.retrieve(; include_meta=false, limitwarn=false)
    flat, frames = Profile.flatten(data, dictionary)
    frame_keys = Dict(address => frame_key(frame) for (address, frame) in frames)
    K = Tuple{String,String,String,Int,Bool}
    inclusive, exclusive = Dict{K,Int}(), Dict{K,Int}()
    stacks = Dict{Vector{K},Int}()
    current = K[]
    samples = 0
    function finish!()
        isempty(current) && return
        samples += 1
        for key in Set(current)
            inclusive[key] = get(inclusive, key, 0) + 1
        end
        julia_leaf = findfirst(key -> !key[5], current)
        if julia_leaf !== nothing
            key = current[julia_leaf]
            exclusive[key] = get(exclusive, key, 0) + 1
        end
        key = copy(current)
        stacks[key] = get(stacks, key, 0) + 1
        empty!(current)
    end
    for address in flat
        if iszero(address)
            finish!()
        elseif haskey(frames, address)
            push!(current, frame_keys[address])
        end
    end
    finish!()
    ordered = sort!(collect(inclusive); by=x -> (-last(x), first(x)))
    flat_rows = [merge(frame_record(key), (; inclusive_samples=count,
        exclusive_julia_leaf_samples=get(exclusive, key, 0))) for (key, count) in ordered]
    stack_rows = sort!(collect(stacks); by=x -> -last(x))
    kept = first(stack_rows, min(length(stack_rows), 1000))
    return (; samples, buffer_full=full, requested_delay_seconds=0.0001,
        sampling_kind="Julia Profile CPU sampling; no wall-time speed estimate",
        counters_are_nonadditive="Inclusive sample counts overlap; do not sum them.",
        signature_text_recorded=false, flat=flat_rows, unique_stacks=length(stack_rows),
        retained_stacks=[(; count, frames=map(frame_record, stack)) for (stack, count) in kept],
        retained_stack_samples=sum(last, kept; init=0), maximum_saved_stacks=1000)
end
end
