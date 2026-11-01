# Host orchestration through Kaimon; both numerical executors are prebuilt.
isdefined(@__MODULE__, :FullXPalmNativePerformance) || include(joinpath(@__DIR__, "full_xpalm_native_performance.jl"))

module FullProgramReuseNativePerformance

using Statistics
import ..FullXPalmNativePerformance as NP

function _metadata(result)
    result.build.available || error("native reuse comparisons require build.toml provenance")
    result.build.trim == "safe" || error("native reuse comparisons require safe trimming")
    result.build.cpu == "generic" || error("native reuse comparisons require generic CPU")
    return (bundle=result.bundle, build=result.build,
        binary_sha256=result.binary_sha256, app_sha256=result.app_sha256)
end

function _summary(trials, arm)
    selected = filter(row -> row.arm === arm, trials)
    return (median_s=median(row.time_s for row in selected),
        min_s=minimum(row.time_s for row in selected), samples=length(selected))
end

"""
    compare_native_reuse(before_bundle, after_bundle; days=60, rate=0.3,
                         reproductive=true, retain=true, repeats=7, cycles=3)

Compare already-compiled before/after full-XPalm executables through Kaimon.
Every cycle launches each arm once, alternating which arm goes first. The
existing `FullXPalmNativePerformance.measure_native` helper runs one P0 warmup
and `repeats` fresh simulations per process, and validates its last full result
against ordinary PSE. P0 measurements remain separate; the default comparison
aggregates 21 measured simulations per arm across three serial processes.

Both executables use the identical internal `simulate_full_xpalm` boundary:
runtime model replacement, fresh MTG/model/RNG/status instantiation, Constants
and forcing construction, then daily steps. Scientific authoring/program
preparation, startup, explicit GC, printing, host parsing and parity checks
are excluded from internal timers. GC during simulation remains included.
This does not measure process launch latency or native allocation bytes.

Both bundles must provide safe/generic build provenance. Binary and app hashes
are captured on the first cycle and checked again on every later cycle;
compiler versions and validated scientific counts must match between arms.
The helper's successful test summaries are suppressed. Returned values contain
only scalar trials, P0 warmups, validation counts, summaries and metadata.
Run on an otherwise idle host without concurrent benchmark computation.
"""
function compare_native_reuse(before_bundle, after_bundle; days=60, rate=0.3,
                              reproductive=true, retain=true, repeats=7, cycles=3)
    cycles isa Integer && cycles > 0 || throw(ArgumentError("cycles must be positive"))
    repeats isa Integer && repeats > 0 || throw(ArgumentError("repeats must be positive"))
    metadata = Dict{Symbol,Any}()
    validated = nothing
    trials = NamedTuple[]
    warmups = NamedTuple[]
    validation = NamedTuple[]
    for cycle in 1:cycles
        order = isodd(cycle) ? (:before, :after) : (:after, :before)
        for arm in order
            bundle = arm === :before ? before_bundle : after_bundle
            result = redirect_stdout(devnull) do
                NP.measure_native(bundle; days, rate, reproductive, retain, repeats, launches=1)
            end
            observed_metadata = _metadata(result)
            if haskey(metadata, arm)
                observed_metadata.binary_sha256 == metadata[arm].binary_sha256 || error("$arm binary changed between cycles")
                isequal(observed_metadata.app_sha256, metadata[arm].app_sha256) || error("$arm app provenance changed between cycles")
                isequal(observed_metadata.build, metadata[arm].build) || error("$arm build provenance changed between cycles")
            else
                metadata[arm] = observed_metadata
            end
            if isnothing(validated)
                validated = result.validated
            else
                isequal(result.validated, validated) || error("before/after scientific validation counts differ")
            end
            for row in result.trials
                push!(trials, (cycle=cycle, arm=arm, launch=cycle, trial=row.trial, time_s=row.time_s))
            end
            for row in result.warmups
                push!(warmups, (cycle=cycle, arm=arm, launch=cycle, trial=row.trial, time_s=row.time_s))
            end
            for row in result.validation
                push!(validation, (cycle=cycle, arm=arm, launch=cycle,
                    passes=row.passes, fails=row.fails, errors=row.errors))
            end
        end
    end
    before_metadata = metadata[:before]
    after_metadata = metadata[:after]
    before_metadata.build.julia == after_metadata.build.julia || error("before/after Julia versions differ")
    before_metadata.build.juliac == after_metadata.build.juliac || error("before/after JuliaC versions differ")
    before = _summary(trials, :before)
    after = _summary(trials, :after)
    return (
        settings=(; days, rate, reproductive, retain, repeats, cycles, architecture=false),
        scope="Identical internal native simulate_full_xpalm boundary; fresh simulation per sample; startup, P0 warmups, explicit GC, serialization and host parity checks excluded",
        metadata=(before=before_metadata, after=after_metadata), validated=validated,
        before=before, after=after, before_over_after_median=before.median_s / after.median_s,
        trials=trials, warmups=warmups, validation=validation,
    )
end

end # module FullProgramReuseNativePerformance
