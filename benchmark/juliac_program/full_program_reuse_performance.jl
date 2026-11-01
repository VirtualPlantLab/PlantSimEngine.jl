# Host-side comparison only. Include and execute through the app's Kaimon
# session; both numerical executors use the same loaded XPalm/PSE packages.
isdefined(@__MODULE__, :FullXPalmPerformance) || include(joinpath(@__DIR__, "full_xpalm_performance.jl"))

module FullProgramReusePerformance

using SHA
import ..FullXPalmPerformance as After

# A separate parent namespace ensures the snapshot's imports of
# ..ReusableProgram/FullXPalmFixture/FullXPalmChecks resolve to its own copies.
module BeforeReuse end
const LOADED_BASELINE = Ref{Union{Nothing,String}}(nothing)

function _load_baseline(baseline_root)
    root = abspath(baseline_root)
    if !isnothing(LOADED_BASELINE[])
        LOADED_BASELINE[] == root || error("this driver already loaded a different baseline; use a fresh Kaimon session")
        return BeforeReuse
    end
    files = (joinpath("app", "src", "program.jl"),
        joinpath("app", "src", "full_xpalm_fixture.jl"),
        "full_xpalm_checks.jl", "full_xpalm_performance.jl")
    all(file -> isfile(joinpath(root, file)), files) || error("baseline_root must contain the snapshot's benchmark/juliac_program directory")
    # Explicit prerequisites are necessary: the old drivers' Main guards see
    # the current modules, even when those drivers are included in this parent.
    for file in files
        Base.include(BeforeReuse, joinpath(root, file))
    end
    LOADED_BASELINE[] = root
    return BeforeReuse
end

function _source_hashes(root)
    files = ("program.jl", "cohort_program.jl", "full_program_plan.jl",
        "full_program_runtime.jl", "full_program_bindings.jl", "full_program_history.jl")
    return Dict(file => bytes2hex(sha256(read(joinpath(root, "app", "src", file)))) for file in files)
end

function _context(performance, settings, forcing, days, retain)
    setup = performance.XF.authoring(; settings...)
    program = performance.RP.prepare(setup.applications; initial=setup.initial.templates)
    return (settings=settings, setup=setup, program=program, forcing=forcing,
        constants=performance.PSE.Constants(), days=Int(days), retain=retain)
end

function _oracle(context)
    source = After._regular_source(context.settings)
    simulation = After._regular_prepared(source, context)
    After._regular_steps!(simulation, context.days)
    return After._observations(simulation, context.setup.variables, context.retain)
end

function _reachable_state_bytes(performance, context, expected)
    state = performance._typed_setup_run(context)
    performance._validate(state, context, expected)
    return Base.summarysize(state)
end

function _comparison_loaded(baseline, baseline_root; days, rate, reproductive, retain, repeats)
    before = baseline.FullXPalmPerformance
    settings = (; rate, reproductive)
    forcing = After.XF.rows(days)
    before_context = _context(before, settings, forcing, days, retain)
    after_context = _context(After, settings, forcing, days, retain)
    before_rng = before.XF.rng_fingerprint(before_context.setup.models)
    after_rng = After.XF.rng_fingerprint(after_context.setup.models)
    expected = _oracle(after_context)

    # Warm the exact fresh-state measurement paths, with all scientific/output
    # validation outside their timers. Each helper returns scalar metrics only.
    before._trial(:setup_and_steps, :typed, before_context, expected, 0)
    After._trial(:setup_and_steps, :typed, after_context, expected, 0)

    # Separately constructed states are measured for reachable heap size, then
    # leave scope before timed samples. This is neither peak RSS nor allocated
    # bytes, and includes the reusable program reachable from each state.
    before_state_bytes = _reachable_state_bytes(before, before_context, expected)
    after_state_bytes = _reachable_state_bytes(After, after_context, expected)
    GC.gc()

    trials = NamedTuple[]
    for trial in 1:repeats
        order = isodd(trial) ? (:before, :after) : (:after, :before)
        for arm in order
            performance, context = arm === :before ? (before, before_context) : (After, after_context)
            measured = performance._trial(:setup_and_steps, :typed, context, expected, trial)
            push!(trials, merge(measured, (arm=arm,)))
        end
    end
    isequal(before.XF.rng_fingerprint(before_context.setup.models), before_rng) || error("baseline caller-owned RNG was mutated")
    isequal(After.XF.rng_fingerprint(after_context.setup.models), after_rng) || error("current caller-owned RNG was mutated")
    before_summary = After._summary(trials, :setup_and_steps, :before)
    after_summary = After._summary(trials, :setup_and_steps, :after)
    return (
        settings=(; days, rate, reproductive, retain, repeats, architecture=false),
        scope="Warm Julia JIT typed runtime, fresh MTG/model/RNG/state instantiation + daily steps; scientific authoring/program preparation/common forcing/GC/validation excluded; not JuliaC/AOT",
        metadata=(current=After._metadata(),
            baseline=(root=abspath(baseline_root), runtime_source_sha256=_source_hashes(baseline_root)),
            current_runtime_source_sha256=_source_hashes(@__DIR__)),
        validated=(objects=length(expected.objects), applications=length(after_context.setup.applications),
            retained_samples=retain ? length(expected.samples) : 0,
            canonical_state=true, full_topology=true, owned_rng=true, retained_sample_parity=retain),
        setup_and_steps=(before=before_summary, after=after_summary,
            before_over_after_median=before_summary.median_s / after_summary.median_s),
        reachable_state_bytes=(before=before_state_bytes, after=after_state_bytes,
            after_over_before=after_state_bytes / before_state_bytes,
            definition="Base.summarysize of separate fresh final states, including reachable program; not peak RSS or allocation volume"),
        trials=trials,
    )
end

"""
    compare_reuse(baseline_root; days=60, rate=0.3, reproductive=true,
                  retain=true, repeats=7)

Compare the current typed full-XPalm runtime with an immutable source snapshot
in the same warmed Kaimon process. `baseline_root` is the snapshot directory
corresponding to `benchmark/juliac_program`, for example the bf4c3ab7 snapshot
at `/private/tmp/pse-reuse-before-bf4c3ab7/benchmark/juliac_program`.

Both arms use separate authored templates/programs and fresh owned scientific
state for every sample. They share plain forcing and one independent ordinary
PSE oracle. Only the typed runtimes are benchmarked. Their existing `_trial`
helpers provide the same setup-and-steps boundary, explicit GC before timing,
and complete canonical/topology/RNG/output validation after timing. One warmup
per exact path precedes alternating before/after trials. `retain=false` checks
canonical state, topology and RNG, without treating internal temporal history
as user-facing retained output.

Separate validated final states provide `Base.summarysize` measurements and
are released before timing. Returned objects contain scalar measurements and
metadata, never full simulations. This is a warm Julia JIT comparison, not a
native JuliaC measurement or a production-year performance guarantee. Run
serially on an otherwise idle host. Only one baseline namespace is loaded per
driver/session; source hashes record the compared runtime files.
"""
function compare_reuse(baseline_root; days=60, rate=0.3, reproductive=true,
                       retain=true, repeats=7)
    days isa Integer && days > 0 || throw(ArgumentError("days must be positive"))
    repeats isa Integer && repeats > 0 || throw(ArgumentError("repeats must be positive"))
    isfinite(rate) && rate >= 0 || throw(ArgumentError("rate must be finite and nonnegative"))
    reproductive isa Bool && retain isa Bool || throw(ArgumentError("reproductive and retain must be Bool"))
    baseline = _load_baseline(baseline_root)
    # Inclusion above defines snapshot methods in a newer world. Enter it once
    # here, outside all timers; calls inside the measured loops remain ordinary.
    return Base.invokelatest(_comparison_loaded, baseline, abspath(baseline_root);
        days, rate, reproductive, retain, repeats)
end

end # module FullProgramReusePerformance
