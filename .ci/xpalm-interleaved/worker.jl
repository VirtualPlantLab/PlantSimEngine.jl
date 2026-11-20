function allocation_steps!(sim, elapsed, counts, bytes)
    before, after = Ref{Int64}(0), Ref{Int64}(0)
    counts[1] = length(PSE.runtime_model(sim).registry.objects)
    for day in eachindex(elapsed)
        Base.gc_bytes(before)
        start = time_ns()
        PSE.step!(sim)
        elapsed[day] = time_ns() - start
        Base.gc_bytes(after)
        bytes[day] = after[] - before[]
        counts[day+1] = length(PSE.runtime_model(sim).registry.objects)
    end
    return nothing
end

function run_worker(directory, role, reference_path)
    @assert VERSION == v"1.13.3"
    @assert Threads.nthreads(:default) == 1 && Threads.ngcthreads() == 1
    @assert realpath(pkgdir(PSE)) == realpath(joinpath(ARMDIR, "..", "PlantSimEngine"))
    @assert realpath(pkgdir(R.XPalm)) == realpath(joinpath(ARMDIR, "..", "XPalm"))
    @assert realpath(pkgdir(R.MTG)) == realpath(joinpath(ARMDIR, "..", "MultiScaleTreeGraph"))
    reference = PSE.JSON.parsefile(reference_path)
    report_path = joinpath(directory, role * ".json")
    replies = []
    first_science = nothing
    Base.cumulative_compile_timing(true)
    try
        for line in eachline(stdin)
            line == "exit" && break
            fields = split(line)
            length(fields) == 4 || error("Invalid benchmark request.")
            seq, phase, mode, index = parse(Int,fields[1]), Symbol(fields[2]), Symbol(fields[3]), parse(Int,fields[4])
            @assert phase in (:warm,:measure,:allocation) && mode in (:full,:daily)
            @assert phase !== :allocation || mode === :daily
            bytes = phase === :allocation ? Vector{Int64}(undef,DAYS) : nothing
            row, counts = trajectory(mode, reference, bytes)
            if isnothing(first_science)
                first_science = row.science
            end
            @assert row.science == first_science
            if phase === :measure
                @assert all(t -> iszero(t.compile_seconds) && iszero(t.recompile_seconds), values(row.times))
                @assert row.after.swap_in == row.before.swap_in && row.after.swap_out == row.before.swap_out
            end
            if mode === :daily
                @assert counts == reference["object_counts"]
                @assert count(>(0),diff(counts)) == reference["growth_days"]
            end
            if mode === :daily && index == 0 && phase === :warm
                observed = (; object_counts=counts, row.science...)
                write(joinpath(directory, role * "-reference.json"), PSE.JSON.json(observed))
            end
            if !isnothing(bytes)
                @assert all(>=(0),bytes)
                growth = diff(counts) .> 0
                observation = (; step_bytes=bytes, growth_bytes=sum(bytes[growth]), ordinary_bytes=sum(bytes[.!growth]))
                write(joinpath(directory,role * "-allocation.json"),PSE.JSON.json(observation))
            end
            push!(replies,(; seq, phase, index, row...))
            # Return pages occupied by completed simulations before the next worker runs.
            GC.gc(true)
            report = (; role,cpu=Sys.CPU_NAME,julia=string(VERSION),julia_commit=Base.GIT_VERSION_INFO.commit,
                hostname=get(ENV,"HOSTNAME",""),pid=getpid(),rows=replies)
            tmp = report_path * ".pending"
            write(tmp,PSE.JSON.json(report))
            mv(tmp, report_path; force=true)
        end
    finally
        Base.cumulative_compile_timing(false)
    end
    return nothing
end
run_worker(ARGS...)
