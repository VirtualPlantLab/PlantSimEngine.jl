# Isolated warmed allocation profiler. Include after call_allocation_probes.jl.
# This stdlib is loaded only by the diagnostic driver, never package source.
import Profile

function _profile_call_type_label(type; limit=350)
    text = string(type)
    return length(text) <= limit ? text : string(first(text, limit), "…")
end

function _profile_call_user_frames(allocation; maxframes=8)
    frames = NamedTuple[]
    for frame in allocation.stacktrace
        frame.from_c && continue
        file = String(frame.file)
        (occursin("PlantSimEngine", file) || occursin("PlantBiophysics", file) ||
            occursin("compiled_regions", file)) || continue
        push!(frames, (function_name=String(frame.func), file,
            line=frame.line, inlined=frame.inlined))
        length(frames) >= maxframes && break
    end
    return Tuple(frames)
end

@noinline function _profile_resolved_kernel_allocations!(target, parent,
    environment, repetitions)
    # This is the exact kernel-only phase that exhibited 480 bytes/iteration.
    # Warm the same concrete invocation before recording every allocation.
    _probe_resolved_kernel!(target, parent, environment, repetitions)
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=1.0 begin
        _probe_resolved_kernel!(target, parent, environment, repetitions)
    end
    return Profile.Allocs.fetch()
end

"""Profile 4–8 warmed unpublished scientific calls on a separate probe fixture."""
function profile_call_allocations(payload::ResolvedRootBatch, environment;
    repetitions=4, depth=1, maxgroups=20)
    context = first(payload.rows).context
    context.time = max(context.time, 1.0)
    target = nothing
    name = nothing
    for level in 1:depth
        entries = [(name, entry) for (name, entry) in pairs(context.calls.entries)
            if entry isa ResolvedCallEntry{true} && _resolved_target_count(entry.plans) > 0]
        isempty(entries) && error("No nonempty resolved call at requested depth")
        name, entry = first(entries)
        target = first(first(entry.plans).targets)
        level == depth || (context = target.context)
    end
    result = _profile_resolved_kernel_allocations!(target, context,
        environment, repetitions)
    grouped = Dict{Any,Int}()
    for allocation in result.allocs
        frames = _profile_call_user_frames(allocation)
        key = (allocation.type, allocation.size, frames)
        grouped[key] = get(grouped, key, 0) + 1
    end
    rows = [(allocation_type=_profile_call_type_label(type),
        bytes_per_allocation=size, count, total_bytes=size * count,
        user_frames=frames) for ((type, size, frames), count) in grouped]
    sort!(rows; by=row -> row.total_bytes, rev=true)
    total_bytes = sum(row.total_bytes for row in rows; init=0)
    user_rows = filter(row -> !isempty(row.user_frames), rows)
    kernel_bytes = sum(row.total_bytes for row in user_rows; init=0)
    return (; repetitions, depth, name, allocations=length(result.allocs),
        total_bytes, bytes_per_kernel=total_bytes / repetitions,
        package_stack_bytes=kernel_bytes,
        package_stack_bytes_per_kernel=kernel_bytes / repetitions,
        unattributed_bytes=total_bytes - kernel_bytes,
        package_stack_groups=user_rows,
        groups=first(rows, min(maxgroups, length(rows))),
        omitted_groups=max(0, length(rows) - maxgroups),
        note=:full_sample_rate_warmed_separate_fixture_unpublished)
end
