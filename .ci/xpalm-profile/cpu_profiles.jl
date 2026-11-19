module MatchedCPUProfiles
using Profile
export initialize!, profile_steps!, summarize

# One allocation for both profiled passages; never clear or resize it in between.
function initialize!()
    Profile.init(; n=20_000_000, delay=0.0001)
    Profile.@profile nothing
    return nothing
end

# The clock result is observed by the caller, so step! cannot become a tailcall.
Base.@noinline function ordinary_step!(step!, simulation)
    step!(simulation)
    return time_ns()
end
Base.@noinline function growth_step!(step!, simulation)
    step!(simulation)
    return time_ns()
end

Base.@noinline function tail_step!(wrapper, step!, simulation)
    wrapper(step!, simulation)
    return time_ns()
end
function tail_start(days)
    isempty(days) && return typemax(Int)
    count = min(32, max(1, length(days) ÷ 2))
    return days[end - count + 1]
end

# One timer covers the passage. Only the selected step has a scoped marker;
# unselected steps and all observations stay outside it. The unprofiled warm
# passage exercises both wrappers with the real step! before either profile.
Base.@constprop :none Base.@noinline function profile_steps!(step!, object_count, simulation,
    expected_counts, sample_mode::Symbol)
    @assert sample_mode in (:none, :ordinary, :growth)
    @assert !Profile.is_running()
    observed = Vector{NamedTuple{(:day, :before, :after, :growth, :sampled, :tail_window, :raw_profile_words, :raw_word_begin, :marker_exit_ns),
        Tuple{Int,Int,Int,Bool,Bool,Bool,Int,Int,UInt64}}}(undef, length(expected_counts) - 1)
    @assert object_count(simulation) == first(expected_counts)
    growth_days = findall(day -> expected_counts[day + 1] > expected_counts[day], eachindex(observed))
    ordinary_days = findall(day -> expected_counts[day + 1] == expected_counts[day], eachindex(observed))
    growth_tail, ordinary_tail = tail_start(growth_days), tail_start(ordinary_days)
    sample_mode === :none || Profile.start_timer()
    try
        for day in eachindex(observed)
            before = object_count(simulation)
            expected_growth = expected_counts[day + 1] > expected_counts[day]
            sampled = sample_mode !== :none && (sample_mode === :growth) == expected_growth
            words_before = Profile.len_data()
            marker_exit_ns = UInt64(0)
            tail_window = day >= (expected_growth ? growth_tail : ordinary_tail)
            if sampled || sample_mode === :none
                wrapper = expected_growth ? growth_step! : ordinary_step!
                marker_exit_ns = tail_window ? tail_step!(wrapper, step!, simulation) : wrapper(step!, simulation)
            else
                step!(simulation)
            end
            words_after = Profile.len_data()
            after = object_count(simulation)
            growth = after > before
            @assert before == expected_counts[day] && after == expected_counts[day + 1]
            @assert growth == expected_growth
            @assert sampled == (sample_mode !== :none && (sample_mode === :growth) == growth)
            observed[day] = (; day, before, after, growth, sampled, tail_window,
                raw_profile_words=Int(words_after - words_before), raw_word_begin=Int(words_before), marker_exit_ns)
        end
    finally
        sample_mode === :none || Profile.stop_timer()
    end
    return observed
end

bounded(s, n) = first(String(s), min(length(String(s)), n))
function frame_key(frame)
    owner = parentmodule(frame)
    module_name = owner === nothing ? (frame.from_c ? "C" : "unknown") : string(owner)
    file = String(frame.file)
    file = replace(file, r"^.*?/PlantSimEngine/" => "PlantSimEngine/")
    file = replace(file, r"^.*?/XPalm/" => "XPalm/")
    # Use only the bare symbol, file and line: never show a MethodInstance/type signature.
    return (bounded(module_name, 100), bounded(frame.func, 180), bounded(file, 260),
        Int(frame.line), frame.from_c)
end
frame_record(key) = (; module_name=key[1], function_name=key[2], file=key[3],
    line=key[4], from_c=key[5])
function summarize(sample_mode::Symbol; after_word::Integer=0, tail_window_days=Int[])
    @assert sample_mode in (:ordinary, :growth)
    @assert !Profile.is_running()
    marker = sample_mode === :ordinary ? :ordinary_step! : :growth_step!
    opposite = sample_mode === :ordinary ? :growth_step! : :ordinary_step!
    full = Profile.is_buffer_full()
    # stop_timer is not a join. Ignore any incomplete trailing block in this
    # immutable copy; a selected main-thread stack is completed before it resumes.
    # Keep the buffer cumulative, avoiding clear/init races between passages.
    raw = Profile.fetch(; include_meta=true, limitwarn=false)
    last_complete = findlast(i -> Profile.is_block_end(raw, i), eachindex(raw))
    @assert 0 <= after_word <= length(raw)
    last_word = isnothing(last_complete) ? 0 : last_complete
    # Drop the entire block crossing the entry cursor, even if it finishes later.
    boundary = iszero(after_word) ? nothing :
        findfirst(i -> i >= after_word && Profile.is_block_end(raw, i), eachindex(raw))
    first_word = iszero(after_word) ? 1 : isnothing(boundary) ? last_word + 1 : boundary + 1
    complete = raw[first_word:last_word]
    incomplete_tail_words = length(raw) - last_word
    data = Profile.strip_meta(complete)
    dictionary = Profile.getdict(data)
    flat, frames = Profile.flatten(data, dictionary)
    frame_keys = Dict(address => frame_key(frame) for (address, frame) in frames)
    marker_keys = Set(frame_keys[address] for (address, frame) in frames
        if frame.func === marker && parentmodule(frame) === @__MODULE__)
    opposite_keys = Set(frame_keys[address] for (address, frame) in frames
        if frame.func === opposite && parentmodule(frame) === @__MODULE__)
    tail_keys = Set(frame_keys[address] for (address, frame) in frames
        if frame.func === :tail_step! && parentmodule(frame) === @__MODULE__)
    K = Tuple{String,String,String,Int,Bool}
    inclusive, exclusive = Dict{K,Int}(), Dict{K,Int}()
    stacks = Dict{Vector{K},Int}()
    current = K[]
    samples = raw_samples = discarded_outside_scope_samples = discarded_opposite_scope_samples = late_window_samples = 0
    function finish!()
        isempty(current) && return
        raw_samples += 1
        selected = any(key -> key in marker_keys, current)
        other = any(key -> key in opposite_keys, current)
        selected && other && error("A sample contains both phase markers.")
        if !selected
            discarded_outside_scope_samples += 1
            discarded_opposite_scope_samples += Int(other)
            empty!(current)
            return
        end
        samples += 1
        late_window_samples += Int(any(key -> key in tail_keys, current))
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
    return (; samples, raw_samples, discarded_outside_scope_samples, late_window_samples, tail_window_days,
        buffer_capacity_words=Profile.maxlen_data(), after_word, first_complete_word=first_word, complete_through_word=last_word,
        discarded_opposite_scope_samples, incomplete_tail_words,
        scope=(; module_name=string(@__MODULE__), function_name=String(marker),
            kind="synchronous selected step stack; other tasks and observations excluded"),
        buffer_full=full, requested_delay_seconds=0.0001,
        sampling_kind="Julia Profile CPU sampling; no wall-time speed estimate",
        counters_are_nonadditive="Inclusive sample counts overlap; do not sum them.",
        signature_text_recorded=false, flat=flat_rows, unique_stacks=length(stack_rows),
        retained_stacks=[(; count, frames=map(frame_record, stack)) for (stack, count) in kept],
        retained_stack_samples=sum(last, kept; init=0), maximum_saved_stacks=1000)
end
end
