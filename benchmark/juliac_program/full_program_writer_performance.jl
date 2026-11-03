# Include in the app's Kaimon session. Both prepared implementations share
# the same ordinary PSE and XPalm modules.
isdefined(@__MODULE__, :FullProgramReusePerformance) ||
    include(joinpath(@__DIR__, "full_program_reuse_performance.jl"))
isdefined(@__MODULE__, :XPalmScaling) || include(joinpath(@__DIR__, "xpalm_scaling.jl"))

module FullProgramWriterPerformance

using Statistics, SHA, Serialization
import ..XPalmScaling as Scaling
import ..FullProgramReusePerformance as Reuse
const CURRENT = Reuse.After

const CASES = (
    (days=60, profile=:accelerated, rate=0.3, reproductive=true, retain=true),
    (days=4160, profile=:package_defaults, rate=0.3, reproductive=false, retain=false),
)
const TIMING_FIELDS = (:authoring, :planning, :preparation, :execution)

_filehash(path) = bytes2hex(sha256(read(path)))
_timed(t) = (seconds=t.time, bytes=t.bytes, gc_s=t.gctime,
    compile_s=t.compile_time, recompile_s=t.recompile_time)
function _setup(p, source)
    xf = p.XF
    palm, applications = source.palm, source.applications
    return (; palm, applications, models=xf.models(applications),
        topology=xf.topology_descriptor(palm), variables=xf.variables_by_category(palm, applications),
        initial=xf.initial_data(palm, applications))
end
function _prepared_context(p, source, settings, forcing, constants)
    setup = _setup(p, source)
    return (; setup, program=Scaling._prepare_current(p, setup), settings,
        days=settings.days, retain=settings.retain, forcing, constants)
end
function _counts(p, result, typed)
    if typed
        return (objects=length(result.nodes), steps=result.step,
            stored_samples=sum(length(stream.retained) for app in result.applications for stream in values(app.streams); init=0))
    end
    return (objects=length(p.PSE.runtime_model(result).registry.objects),
        steps=p.PSE.current_step(result),
        stored_samples=sum(length, values(p.PSE.outputs(result)); init=0))
end
function _timed_trial(p, context, expected, arm, trial)
    GC.gc()
    authoring = @timed Scaling._source(p, context.settings)
    if arm === :ordinary
        planning = (seconds=0.0, bytes=0, gc_s=0.0, compile_s=0.0, recompile_s=0.0)
        prep = @timed p._regular_prepared(authoring.value, context)
        exec = @timed p._regular_steps!(prep.value, context.days)
        typed = false
    else
        planned = @timed _prepared_context(p, authoring.value, context.settings, context.forcing, context.constants)
        planning = _timed(planned)
        prep = @timed p._typed_prepared(planned.value)
        exec = @timed p._typed_steps!(prep.value, context.forcing, context.constants)
        typed = true
    end
    Scaling._validate(p, exec.value, context, expected, typed)
    return (; arm, trial, authoring=_timed(authoring), planning, preparation=_timed(prep),
        execution=_timed(exec), counts=_counts(p, exec.value, typed))
end
function _step_timing!(result, forcing, advance!, object_count)
    ns_growing, ns_other = UInt64(0), UInt64(0)
    growing, other, added = 0, 0, 0
    previous = object_count(result)
    initial = previous
    for row in forcing
        start = time_ns()
        advance!(result, row)
        elapsed = time_ns() - start
        current = object_count(result)
        if current > previous
            ns_growing += elapsed
            growing += 1
            added += current - previous
        else
            ns_other += elapsed
            other += 1
        end
        previous = current
    end
    return (; growth_steps=growing, other_steps=other, net_added=added,
        initial_objects=initial, final_objects=previous,
        growth_step_seconds=ns_growing/1e9, other_step_seconds=ns_other/1e9)
end
function _step_diagnostic(p, ctx, expected, typed)
    if typed
        result = p._typed_prepared(ctx)
        advance = let step! = p.RP.step!, constants = ctx.constants
            (state, row) -> step!(state, row; constants)
        end
        count_objects = state -> length(state.nodes)
    else
        result = p._regular_prepared(Scaling._source(p, ctx.settings), ctx)
        advance = let step! = p.PSE.step!
            (state, _) -> step!(state)
        end
        count_objects = let model = p.PSE.runtime_model
            state -> length(model(state).registry.objects)
        end
    end
    measured = @timed _step_timing!(result, ctx.forcing, advance, count_objects)
    Scaling._validate(p, result, ctx, expected, typed)
    return merge(measured.value, (reachable_bytes=Base.summarysize(result),
        compile_s=measured.compile_time, recompile_s=measured.recompile_time))
end
function _phase_summary(rows, arm)
    trials = filter(r -> r.arm === arm, rows)
    values = map(TIMING_FIELDS) do field
        phase = [getproperty(row, field) for row in trials]
        (median_s=median(x.seconds for x in phase), median_bytes=median(x.bytes for x in phase),
            median_gc_s=median(x.gc_s for x in phase), min_s=minimum(x.seconds for x in phase))
    end
    return NamedTuple{TIMING_FIELDS}(values)
end
function _source_image(root)
    files = sort!([joinpath(dir, file) for component in ("src","ext")
        for (dir, _, files) in walkdir(joinpath(root,component)) for file in files])
    return Dict(relpath(file,root) => _filehash(file) for file in files)
end
function _paths_image(baseline)
    candidate = Reuse._source_hashes(@__DIR__)
    return (; baseline=Reuse._source_hashes(baseline), candidate,
        fixture=(baseline=_filehash(joinpath(baseline,"app","src","full_xpalm_fixture.jl")),
            candidate=_filehash(joinpath(@__DIR__,"app","src","full_xpalm_fixture.jl"))),
        pse=_source_image(pkgdir(CURRENT.PSE)), xpalm=_source_image(pkgdir(CURRENT.XPalm)),
        manifest=_filehash(joinpath(pwd(),"Manifest.toml")), driver=_filehash(@__FILE__))
end
function _compare(before_module, baseline, baseline_revision, destination, settings, progress)
    before = _paths_image(baseline)
    before.fixture.baseline == before.fixture.candidate || error("scientific fixture differs")
    before.pse == _source_image(realpath(joinpath(baseline,"../.."))) || error("ordinary PSE source differs across snapshots")
    forcing, constants = CURRENT.XF.rows(settings.days), CURRENT.PSE.Constants()
    ctx(p) = _prepared_context(p, Scaling._source(p, settings), settings, forcing, constants)
    oracle_path = joinpath(destination,"ordinary-$(settings.days)-expected.jls")
    # Build a fresh independent ordinary oracle in this process before warming
    # the measured paths. Existing receipt files cannot replace this oracle.
    source = Scaling._source(CURRENT, settings)
    oracle_context = (; setup=_setup(CURRENT, source), settings, days=settings.days, retain=settings.retain)
    expected = Scaling._oracle(CURRENT, oracle_context, nothing)
    open(io -> serialize(io, expected), oracle_path, "w")
    println(progress, "oracle ", oracle_path); flush(progress)
    contexts = (before=ctx(before_module), after=ctx(CURRENT))
    rows = NamedTuple[]
    arms = (:ordinary, :before, :after)
    select(arm) = arm === :before ? (before_module, contexts.before) : (CURRENT, contexts.after)
    for arm in arms
        perf, context = select(arm)
        row = _timed_trial(perf, context, expected, arm, 0)
        println(progress, "warmup ", arm, " ", row.counts); flush(progress)
    end
    for trial in 1:6
        order = circshift(collect(arms), (trial-1)÷2 % length(arms))
        iseven(trial) && reverse!(order)
        for arm in order
            perf, context = select(arm)
            row = _timed_trial(perf, context, expected, arm, trial)
            all(field -> begin phase=getproperty(row,field); iszero(phase.compile_s) && iszero(phase.recompile_s) end, TIMING_FIELDS) ||
                error("compiled during measured trial $trial $arm: $row")
            push!(rows, row)
            println(progress, "sample ", trial, " ", arm, " ", row.execution.seconds); flush(progress)
        end
    end
    diagnostics = NamedTuple[]
    for arm in arms
        perf, context = select(arm)
        GC.gc()
        _step_diagnostic(perf, context, expected, arm !== :ordinary)
    end
    for trial in 1:4
        order = isodd(trial) ? (:before, :after) : (:after, :before)
        for arm in (trial == 1 ? (order..., :ordinary) : order)
            perf, context = select(arm)
            GC.gc()
            row = _step_diagnostic(perf, context, expected, arm !== :ordinary)
            iszero(row.compile_s) && iszero(row.recompile_s) || error("diagnostic compiled: $row")
            push!(diagnostics, merge((; arm, trial), row))
        end
    end
    isequal(_paths_image(baseline), before) || error("source or manifest image changed")
    summaries = NamedTuple{arms}(map(arm -> _phase_summary(rows,arm), arms))
    report = (; settings, baseline_root=baseline, baseline_revision, metadata=before,
        candidate_revision=CURRENT._metadata().source_revision, julia=string(VERSION),
        cpu=Sys.CPU_NAME, threads=Threads.nthreads(), repeats=6, summaries, rows,
        diagnostics, oracle_sha256=_filehash(oracle_path),
        parity=(canonical_state=true, topology=true, rng=true, retained_samples=settings.retain,
            objects=length(expected.objects), samples=length(expected.samples)))
    path = joinpath(destination,"comparison-$(settings.days).json")
    write(path*".partial", CURRENT.PSE.JSON.json(report))
    mv(path*".partial",path;force=true)
    println(progress,"PASS ",path); flush(progress)
    return path
end

"""
    compare_writers(baseline, destination; days, baseline_revision, progress=stdout)

Compare a frozen pre-writer-validation runtime with the current prepared XPalm
runtime and ordinary PSE. Pass the snapshot's `benchmark/juliac_program` directory
as `baseline`, its archive commit as `baseline_revision`, and an empty scratch
directory as `destination`. Both arms must
have the same ordinary PSE source and XPalm fixture. Run through a Kaimon session
at `app/` on a quiet host. Select `days=60` for the retained accelerated
reproductive case or `days=4160` for unchanged package parameters and no
requested retained output.

Six balanced warm trials separate scientific authoring, reusable planning,
runtime preparation and daily execution. All parity checks run after timers.
Four additional typed trials split whole daily steps by whether objects were
added. These diagnostic step groups include all work on each day. The ordinary
reference snapshot and raw JSON are written to the scratch directory.
"""
function compare_writers(baseline, destination; days, baseline_revision, progress=stdout)
    settings = only(filter(case -> case.days == days, CASES))
    baseline = abspath(baseline)
    destination = mkpath(abspath(destination))
    any(ispath, (joinpath(destination, "comparison-$days.json"),
                 joinpath(destination, "ordinary-$days-expected.jls"))) &&
        error("use a fresh result directory")
    previous = Reuse._load_baseline(baseline)
    return Base.invokelatest(
        () -> _compare(previous.FullXPalmPerformance, baseline, baseline_revision, destination, settings, progress),
    )
end

end # module FullProgramWriterPerformance
