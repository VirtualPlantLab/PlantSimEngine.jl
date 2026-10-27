module MAESPADownstreamProfile

using Profile, Serialization

isdefined(Main, :MAESPADownstreamBenchmark) || error("Include downstream_maespa/run.jl first")
const Audit = Main.MAESPADownstreamBenchmark
const PSE = Audit.PSE

function _profile_steps!(simulations)
    for simulation in simulations
        PSE.continue!(simulation; steps=96)
    end
    return nothing
end

function package_roots()
    return Dict(
        "MAESPA" => normpath(pkgdir(Audit.MAESPA)),
        "PlantSimEngine" => normpath(pkgdir(PSE)),
        "PlantMeteo" => normpath(pkgdir(Audit.MAESPA.PlantMeteo)),
    )
end

function package_owner(frame, roots)
    file = string(frame.file)
    for owner in ("MAESPA", "PlantSimEngine", "PlantMeteo")
        startswith(file, roots[owner] * "/") && return owner
    end
    return nothing
end

function nearest_owner(frames, roots)
    for frame in frames
        file, func = string(frame.file), string(frame.func)
        (occursin("/compiler/", file) || startswith(file, "compiler/")) &&
            return "compiler", frame
        occursin(r"gc_(collect|mark|sweep|scan|queue|wait_for_the_world|stop_the_world)", func) &&
            return "GC", frame
        owner = package_owner(frame, roots)
        isnothing(owner) || return owner, frame
    end
    return "other", first(frames)
end

frame_key(frame) = (file=string(frame.file), func=string(frame.func), line=Int(frame.line))
ranked(counts; limit=35) = [merge(site, (samples=count,)) for (site, count) in
    first(sort!(collect(counts); by=pair -> (-last(pair), repr(first(pair)))),
        min(limit, length(counts)))]

function summarize(data, dictionary, roots)
    owners = Dict(owner => 0 for owner in
        ("MAESPA", "PlantSimEngine", "PlantMeteo", "GC", "compiler", "other"))
    owner_sites = Dict{NamedTuple,Int}()
    inclusive_sites = Dict{NamedTuple,Int}()
    leaf_sites = Dict{NamedTuple,Int}()
    counts = [0, 0]
    frames = Base.StackTraces.StackFrame[]
    function visit_stack!()
        isempty(frames) && return nothing
        counts[1] += 1
        any(frame -> string(frame.func) == "_profile_steps!", frames) || return nothing
        counts[2] += 1
        owner, frame = nearest_owner(frames, roots)
        owners[owner] += 1
        site = merge((owner=owner,), frame_key(frame))
        owner_sites[site] = get(owner_sites, site, 0) + 1
        leaf = frame_key(first(frames))
        leaf_sites[leaf] = get(leaf_sites, leaf, 0) + 1
        for site in Set(frame_key(frame) for frame in frames
            if !isnothing(package_owner(frame, roots)))
            inclusive_sites[site] = get(inclusive_sites, site, 0) + 1
        end
        return nothing
    end
    for address in data
        if iszero(address)
            visit_stack!()
            empty!(frames)
        else
            append!(frames, get(dictionary, address, Base.StackTraces.StackFrame[]))
        end
    end
    visit_stack!()
    counts[2] > 0 || error("No CPU samples contain _profile_steps!")
    @assert sum(values(owners)) == counts[2]
    return (
        total_stacks=counts[1], selected_stacks=counts[2], exclusive_owners=owners,
        exclusive_owner_percent=Dict(owner => 100 * count / counts[2] for (owner, count) in owners),
        exclusive_sites=ranked(owner_sites), inclusive_sites=ranked(inclusive_sites),
        leaf_frames=ranked(leaf_sites),
    )
end

"""
    run_profile(label, output_directory; runs=8, delay=0.001)

Run only after the unprofiled comparisons. Model construction and zero-step
initialization happen before sampling. Package attribution uses actual loaded
package directories, including a candidate checkout whose name is unrelated to
PlantSimEngine. Other task stacks are excluded using the profiling wrapper.
"""
function run_profile(label, output_directory; runs=8, delay=0.001)
    runs > 0 || throw(ArgumentError("runs must be positive"))
    simulations = [PSE.run!(Audit.two_species_model(); steps=0, outputs=:none) for _ in 1:runs]
    _profile_steps!(simulations[1:0])
    Profile.init(n=20_000_000, delay=delay)
    Profile.clear()
    GC.gc()
    timing = @timed Profile.@profile _profile_steps!(simulations)
    data, dictionary = Profile.retrieve(include_meta=false)
    mkpath(output_directory)
    serialize(joinpath(output_directory, "cpu_profile.jls"), (data, dictionary))
    roots = package_roots()
    summary = summarize(data, dictionary, roots)
    checks = [Audit.check_result(simulation) for simulation in simulations]
    result = merge(summary, (
        label=label, runs=runs, delay=delay, steps_per_run=96, outputs="none",
        sampled_region="96-step continuation only", profile_wall_timing=Audit.metrics(timing),
        package_roots=roots, provenance=Audit.provenance(label), smoke_checks=checks,
        profile_source_sha256=Audit.file_digest(@__FILE__),
        notes=["Profiled wall time is diagnostic, not an unprofiled benchmark result.",
            "Ownership is the nearest package, compiler or GC frame; inclusive sites overlap."],
    ))
    Audit.save_toml(joinpath(output_directory, "cpu_attribution.toml"), result)
    return (selected_stacks=summary.selected_stacks, owners=summary.exclusive_owners,
        top_sites=first(summary.exclusive_sites, min(12, length(summary.exclusive_sites))),
        smoke_checks=checks)
end

end
