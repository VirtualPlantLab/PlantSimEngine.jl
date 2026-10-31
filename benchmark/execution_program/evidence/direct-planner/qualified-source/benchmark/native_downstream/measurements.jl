module NativeDownstreamMeasurements

using Dates
using SHA
using Statistics

export VariantSpec, CaseSpec, register_case!, registered_cases, measure_case,
    screen_case, summarize_screen, source_manifest, package_provenance,
    process_provenance, small_matrix, scaling_matrix, compilation_matrix,
    measurement_harness_checks, required_feature_gates

"""An arm's claimed mechanism; claims require positive executed coverage."""
struct VariantSpec
    name::Symbol
    needs_native::Bool
    needs_driver::Bool
end
VariantSpec(name::Symbol; native=false, driver=false) = VariantSpec(name, native, driver)

const DEFAULT_VARIANTS = (
    VariantSpec(:reference_executor),
    VariantSpec(:reference_driver; driver=true),
    VariantSpec(:native_executor; native=true),
    VariantSpec(:native_driver; native=true, driver=true),
)

"""
Named configuration and callbacks for an independently constructed sample.

Callbacks have these signatures (all diagnostics run after timed execution):

  * `construct(config, variant) -> fixture`
  * `prepare(fixture, config, variant) -> simulation`
  * `lower(simulation, fixture, config, variant) -> program`
  * `execute!(simulation, program, fixture, config, variant)`
  * `fingerprint(simulation, fixture, config) -> complete semantic snapshot`
  * `coverage(simulation, program, fixture, config, variant) -> NamedTuple`
  * `work(simulation, fixture, config) -> NamedTuple`

`prepare` includes ordinary PSE compilation and zero-step runtime preparation.
`lower` includes only the additional backend. Keep weather-file reads, imports,
source audits and diagnostic IR probes outside every timed phase. Construct new
mutable scenario/model/RNG state in `construct` for every sample. A fingerprint
must include object IDs, exact numeric types and values, histories and current
time. Normalize only the intentionally changed carrier backing representation.

Coverage must supply `native_fields`, `driver_units`, and `native_driver_units`:
native fields selected by execution, actual optimized kernel/root executions,
and optimized executions borrowing native canonical fields respectively. Pool
allocation counts alone do not establish native execution. Additional report
fields, including rejection/fallback counts, are retained without alteration.

`packages` is a tuple of loaded modules, used only for provenance. Optional
downstream dependencies are never added to the ordinary benchmark project.
"""
struct CaseSpec{C,F,P,L,E,S,V,W,M}
    name::Symbol
    config::C
    construct::F
    prepare::P
    lower::L
    execute!::E
    fingerprint::S
    coverage::V
    work::W
    packages::M
    variants::Tuple
end

const CASES = Dict{Symbol,Any}()
const FIRST_USE_RECORDS = Set{Tuple{Symbol,Symbol}}()
const MEASUREMENT_COUNT = Ref(0)

function register_case!(name::Symbol; config, construct, prepare, lower, execute!,
    fingerprint, coverage, work=(simulation, fixture, config) -> (;),
    packages=(), variants=DEFAULT_VARIANTS, replace=false)
    haskey(CASES, name) && !replace && throw(ArgumentError("Case $(name) is already registered"))
    isempty(variants) && throw(ArgumentError("At least one variant is required"))
    all(arm -> arm isa VariantSpec, variants) || throw(ArgumentError("Use VariantSpec arms"))
    names = map(arm -> arm.name, variants)
    length(unique(names)) == length(names) || throw(ArgumentError("Variant names must be unique"))
    spec = CaseSpec(name, config, construct, prepare, lower, execute!, fingerprint,
        coverage, work, packages, Tuple(variants))
    CASES[name] = spec
    return spec
end

registered_cases() = sort!(collect(keys(CASES)))

function _resolve_variant(spec::CaseSpec, name::Symbol)
    index = findfirst(arm -> arm.name === name, spec.variants)
    isnothing(index) && throw(ArgumentError("Unknown variant $(name) for $(spec.name)"))
    return spec.variants[index]
end
_resolve_variant(spec::CaseSpec, variant::VariantSpec) = _resolve_variant(spec, variant.name)

function measurement_phase(measurement)
    stats = hasproperty(measurement, :gcstats) ? measurement.gcstats : nothing
    portable_stats = isnothing(stats) ? nothing :
        NamedTuple{fieldnames(typeof(stats))}(Tuple(getfield(stats, field) for field in fieldnames(typeof(stats))))
    return (seconds=measurement.time, allocated_bytes=measurement.bytes,
        gc_seconds=measurement.gctime,
        gc_stats=portable_stats,
        compilation_seconds=hasproperty(measurement, :compile_time) ? measurement.compile_time : nothing,
        recompilation_seconds=hasproperty(measurement, :recompile_time) ? measurement.recompile_time : nothing)
end

"""Full per-file SHA-256 provenance, including the active project's dependency files."""
function source_manifest(root::AbstractString; directories=("src", "benchmark/native_downstream"),
    exclude_directories=(".git", "results"))
    root = abspath(root)
    paths = String[]
    for directory in directories
        full = joinpath(root, directory)
        isdir(full) || continue
        for (parent, children, files) in walkdir(full)
            filter!(child -> !(child in exclude_directories), children)
            for file in files
                endswith(file, ".jl") || continue
                push!(paths, joinpath(parent, file))
            end
        end
    end
    for file in ("Project.toml", "Manifest.toml")
        full = joinpath(root, file)
        isfile(full) && push!(paths, full)
    end
    rows = [(path=relpath(path, root), sha256=bytes2hex(sha256(read(path))))
        for path in sort!(unique!(paths))]
    aggregate = bytes2hex(sha256(join((row.path * "\0" * row.sha256 for row in rows), "\n")))
    return (; root, aggregate_sha256=aggregate, files=rows)
end

function _git_read(root, args...)
    try
        return readchomp(Cmd(["git", "-C", root, args...]))
    catch error
        return (unavailable=true, reason=sprint(showerror, error))
    end
end

function package_provenance(package::Module)
    root = pkgdir(package)
    version = Base.pkgversion(package)
    return (name=string(nameof(package)), path=Base.pathof(package), root,
        version=isnothing(version) ? nothing : string(version),
        revision=_git_read(root, "rev-parse", "HEAD"),
        worktree_status=_git_read(root, "status", "--porcelain=v1", "--untracked-files=no"),
        sources=source_manifest(root))
end

function process_provenance(; packages=())
    project = Base.active_project()
    manifest = isnothing(project) ? nothing : joinpath(dirname(project), "Manifest.toml")
    return (recorded_at_utc=string(Dates.now(Dates.UTC)), process_id=getpid(),
        julia=string(VERSION), executable=joinpath(Sys.BINDIR, Base.julia_exename()),
        cpu=Sys.CPU_NAME, architecture=string(Sys.ARCH), kernel=string(Sys.KERNEL),
        threads=Threads.nthreads(), active_project=project,
        active_project_sha256=isnothing(project) || !isfile(project) ? nothing : bytes2hex(sha256(read(project))),
        active_manifest=manifest,
        active_manifest_sha256=isnothing(manifest) || !isfile(manifest) ? nothing : bytes2hex(sha256(read(manifest))),
        packages=map(package_provenance, packages),
        harness=source_manifest(@__DIR__; directories=(".",)),
        experimental_sources=source_manifest(joinpath(@__DIR__, "../..");
            directories=("benchmark/native_downstream", "benchmark/compiled_regions",
                "benchmark/generated_program")))
end

_highwater_rss() = try Sys.maxrss() catch; nothing end

function _assert_coverage(variant::VariantSpec, coverage)
    for field in (:native_fields, :driver_units, :native_driver_units)
        hasproperty(coverage, field) || throw(ArgumentError("Coverage lacks $(field)"))
        value = getproperty(coverage, field)
        value isa Real && isfinite(value) && value >= 0 ||
            throw(ArgumentError("Coverage $(field) must be finite and nonnegative"))
    end
    variant.needs_native && iszero(coverage.native_fields) &&
        error("Arm $(variant.name) executed no selected native canonical field")
    variant.needs_driver && iszero(coverage.driver_units) &&
        error("Arm $(variant.name) executed no optimized driver unit")
    variant.needs_native && variant.needs_driver && iszero(coverage.native_driver_units) &&
        error("Arm $(variant.name) executed no optimized unit borrowing native canonical fields")
    return nothing
end

function _first_use_attestation(spec, variant, temperature, freshness)
    temperature in (:first_use, :warm, :warmup) || throw(ArgumentError("Unknown temperature $(temperature)"))
    temperature === :first_use || return nothing
    isnothing(freshness) && throw(ArgumentError("First-use measurement requires an explicit freshness attestation"))
    for field in (:new_process, :no_prior_case_execution, :no_prior_ir_probe)
        hasproperty(freshness, field) && getproperty(freshness, field) === true ||
            throw(ArgumentError("First-use attestation must confirm $(field)=true"))
    end
    iszero(MEASUREMENT_COUNT[]) || error("A prior harness sample already ran in this process")
    key = (spec.name, variant.name)
    key in FIRST_USE_RECORDS && error("This case/arm already has a first-use record in this process")
    isempty(FIRST_USE_RECORDS) || error("Use a separate new Kaimon process for every cold arm")
    push!(FIRST_USE_RECORDS, key)
    return nothing
end

"""
Measure a single fresh scenario. First-use timings precede fingerprints, coverage,
memory inspection, tracing and IR probes. A cold comparison needs one new Kaimon
process per arm; include package-import time in a separate externally timed record.
Julia compilation accumulated inside each phase is reported separately from the
ordinary PSE preparation phase. Wrapper/import compilation is not silently added.
Each callback crosses invokelatest once, preventing its model specialization from
being compiled as part of this measurement wrapper before the phase timer starts.
This same single dynamic boundary is used for all warm and cold comparison arms.
"""
function measure_case(spec::CaseSpec, variant_name;
    temperature=:warm, expected_digest=nothing, freshness=nothing,
    provenance=nothing, measure_retained=false, pre_sample_gc=true)
    variant = _resolve_variant(spec, variant_name)
    _first_use_attestation(spec, variant, temperature, freshness)
    provenance = isnothing(provenance) ? process_provenance(; packages=spec.packages) : provenance
    MEASUREMENT_COUNT[] += 1
    pre_sample_gc && GC.gc()
    rss_before = _highwater_rss()
    construction = @timed Base.invokelatest(spec.construct, spec.config, variant)
    fixture = construction.value
    preparation = @timed Base.invokelatest(spec.prepare, fixture, spec.config, variant)
    simulation = preparation.value
    lowering = @timed Base.invokelatest(spec.lower, simulation, fixture, spec.config, variant)
    program = lowering.value
    execution = @timed Base.invokelatest(spec.execute!, simulation, program, fixture, spec.config, variant)
    rss_after = _highwater_rss()

    # Do not move these diagnostics ahead of first execution. Even a seemingly
    # harmless report can compile a scientific kernel or materialize lazy views.
    snapshot = spec.fingerprint(simulation, fixture, spec.config)
    digest = bytes2hex(sha256(repr(snapshot)))
    isnothing(expected_digest) || digest == expected_digest ||
        error("Full semantic fingerprint mismatch: $(spec.name)/$(variant.name)")
    coverage = spec.coverage(simulation, program, fixture, spec.config, variant)
    _assert_coverage(variant, coverage)
    work = spec.work(simulation, fixture, spec.config)
    retained = measure_retained ? (
        simulation_bytes=Base.summarysize(simulation),
        simulation_program_fixture_bytes=Base.summarysize((simulation, program, fixture)),
        meaning=:reachable_object_size_not_RSS_or_cumulative_allocations) : nothing
    phases = (construction=measurement_phase(construction),
        pse_preparation=measurement_phase(preparation),
        backend_lowering=measurement_phase(lowering),
        execution=measurement_phase(execution))
    return (case=spec.name, config=spec.config, variant=variant.name, temperature,
        freshness, process_id=getpid(), phases, digest, snapshot, coverage, work,
        retained, rss=(before_highwater_bytes=rss_before, after_highwater_bytes=rss_after,
            meaning=:process_lifetime_highwater_not_case_peak_or_reachable_size),
        complete_seconds=sum(phase.seconds for phase in values(phases)),
        complete_allocated_bytes=sum(phase.allocated_bytes for phase in values(phases)),
        complete_gc_seconds=sum(phase.gc_seconds for phase in values(phases)),
        provenance)
end
measure_case(name::Symbol, variant; kwargs...) = measure_case(CASES[name], variant; kwargs...)

"""Small warm serial screen with fresh scenarios and alternating AB/BA arm order."""
function screen_case(spec::CaseSpec; baseline=:reference_executor,
    variants=map(arm -> arm.name, spec.variants), repetitions=3,
    pre_sample_gc=true, measure_retained=true)
    repetitions > 0 || throw(ArgumentError("repetitions must be positive"))
    baseline in variants || throw(ArgumentError("Include the baseline in every screen"))
    provenance = process_provenance(; packages=spec.packages)
    shared_provenance = (record=:screen_provenance,)
    # Always establish the baseline fingerprint first, irrespective of arm order.
    first_warmup = measure_case(spec, baseline; temperature=:warmup, pre_sample_gc,
        provenance=shared_provenance)
    expected = first_warmup.digest
    warmups = Any[first_warmup]
    for variant in variants
        variant === baseline && continue
        push!(warmups, measure_case(spec, variant; temperature=:warmup,
            expected_digest=expected, pre_sample_gc, provenance=shared_provenance))
    end
    samples = Any[]
    orders = Any[]
    for cycle in 1:repetitions
        order = isodd(cycle) ? variants : reverse(variants)
        push!(orders, collect(order))
        for variant in order
            record = measure_case(spec, variant; expected_digest=expected,
                measure_retained=measure_retained && cycle == 1, pre_sample_gc,
                provenance=shared_provenance)
            push!(samples, (; cycle, record...))
        end
    end
    return (case=spec.name, config=spec.config, baseline, repetitions, orders,
        expected_digest=expected, provenance, warmups, samples,
        interpretation=:warm_serial_screen_not_cold_compilation_or_biological_validation)
end
screen_case(name::Symbol; kwargs...) = screen_case(CASES[name]; kwargs...)

function summarize_screen(screen)
    controls = Dict(row.cycle => row for row in screen.samples if row.variant === screen.baseline)
    return [begin
        rows = filter(row -> row.variant === variant, screen.samples)
        ratios = [(execution=row.phases.execution.seconds / controls[row.cycle].phases.execution.seconds,
            complete=row.complete_seconds / controls[row.cycle].complete_seconds) for row in rows]
        (variant, samples=length(rows),
            execution_seconds=median(row.phases.execution.seconds for row in rows),
            complete_seconds=median(row.complete_seconds for row in rows),
            execution_allocated_bytes=median(row.phases.execution.allocated_bytes for row in rows),
            complete_allocated_bytes=median(row.complete_allocated_bytes for row in rows),
            execution_ratio=median(row.execution for row in ratios),
            complete_ratio=median(row.complete for row in ratios), cycle_ratios=ratios,
            phase_compilation=[NamedTuple{keys(row.phases)}(Tuple(
                (compilation_seconds=phase.compilation_seconds,
                    recompilation_seconds=phase.recompilation_seconds)
                for phase in values(row.phases))) for row in rows],
            coverage=[row.coverage for row in rows], retained=first(rows).retained)
    end for variant in unique(row.variant for row in screen.samples)]
end

# These records are requests, not measurements. Width and object scaling are
# separate experiments so a larger biological scene is not mistaken for more
# compiled model types. Callers bind each record to the appropriate CaseSpec.
small_matrix() = (
    (name=:pb_small, kind=:plantbiophysics, nobjects=4, steps=2, seed=1),
    (name=:xp_growth_small, kind=:xpalm, npalms=1, steps=4, seed=1,
        emission_speed=0.2, architecture=false),
)
scaling_matrix() = (
    (name=:pb_32, kind=:plantbiophysics, nobjects=32, steps=8, seed=1),
    (name=:pb_256, kind=:plantbiophysics, nobjects=256, steps=8, seed=1),
    (name=:generic_32, kind=:generic, nobjects=32, nmodels=4, steps=256, seed=1),
    (name=:generic_256, kind=:generic, nobjects=256, nmodels=4, steps=256, seed=1),
)
compilation_matrix() = (
    (name=:width_4, kind=:generic, nobjects=4, nmodels=4, steps=1, seed=1),
    (name=:width_16, kind=:generic, nobjects=4, nmodels=16, steps=1, seed=1),
    (name=:width_64, kind=:generic, nobjects=4, nmodels=64, steps=1, seed=1),
    (name=:pb_realistic_compile, kind=:plantbiophysics, nobjects=4, steps=2, seed=1),
    (name=:xp_realistic_compile, kind=:xpalm, npalms=1, steps=4, seed=1,
        emission_speed=0.2, architecture=false),
)

"""Feature evidence required before extrapolating a backend's package timings."""
required_feature_gates() = (
    :explicit_status_and_reference_identity,
    :raw_initial_schema_and_exact_numeric_types,
    :newborn_native_defaults_before_initializer,
    :same_object_and_cross_object_one,
    :optional_one_and_many_identity_alignment,
    :distributed_destination_coverage_and_atomic_assignment,
    :hard_call_selected_targets_and_iterative_trials,
    :evaluate_accept_nested_publication_and_rejection,
    :global_spatial_and_trial_environment_sampling,
    :temporal_streams_and_previous_step,
    :ordinary_continue_after_backend_execution,
    :addition_removal_reparenting_and_movement,
    :templates_instances_overrides_and_stale_program,
    :numeric_aliases_and_mutable_values,
    :positive_executed_native_and_driver_coverage,
)

function _expect_protocol_error(callback)
    try
        callback()
    catch
        return true
    end
    error("Expected protocol rejection did not occur")
end

"""
Dependency-free protocol gate. Uses tiny mutable counters, no PSE/PB/XP kernels.
Checks that a claimed optimization cannot pass without executed coverage, that
fingerprint mismatch is rejected, and that repeated samples are
independent and ordered. Run this in a helper session, never before a cold case.
"""
function measurement_harness_checks()
    arms = (VariantSpec(:reference_executor), VariantSpec(:native_driver; native=true, driver=true))
    spec = register_case!(:_measurement_protocol_check;
        config=(steps=2, seed=1), variants=arms, replace=true,
        construct=(config, variant) -> (state=Ref(0), history=Int[]),
        prepare=(fixture, config, variant) -> fixture,
        lower=(simulation, fixture, config, variant) -> nothing,
        execute! = (simulation, program, fixture, config, variant) -> begin
            for _ in 1:config.steps
                simulation.state[] += 1
                push!(simulation.history, simulation.state[])
            end
            nothing
        end,
        fingerprint=(simulation, fixture, config) ->
            (value=simulation.state[], value_type=string(typeof(simulation.state[])),
                history=copy(simulation.history)),
        coverage=(simulation, program, fixture, config, variant) ->
            (native_fields=variant.needs_native ? 1 : 0,
                driver_units=variant.needs_driver ? config.steps : 0,
                native_driver_units=variant.needs_native && variant.needs_driver ? config.steps : 0))
    screen = screen_case(spec; repetitions=2, measure_retained=false)
    @assert length(screen.samples) == 4
    @assert screen.orders[1] == [:reference_executor, :native_driver]
    @assert screen.orders[2] == [:native_driver, :reference_executor]
    @assert all(row -> row.snapshot.value == 2 && row.snapshot.history == [1, 2], screen.samples)
    @assert all(row -> keys(row.phases) == (:construction, :pse_preparation,
        :backend_lowering, :execution), screen.samples)
    @assert length(summarize_screen(screen)) == 2
    no_op_rejected = _expect_protocol_error(() -> _assert_coverage(last(arms),
        (native_fields=1, driver_units=0, native_driver_units=0)))
    disconnected_native_rejected = _expect_protocol_error(() -> _assert_coverage(last(arms),
        (native_fields=1, driver_units=2, native_driver_units=0)))
    parity_rejected = _expect_protocol_error(() -> measure_case(spec, :reference_executor;
        expected_digest="deliberately_wrong"))
    no_attestation_rejected = _expect_protocol_error(() ->
        _first_use_attestation(spec, first(arms), :first_use, nothing))
    warm_process_cold_claim_rejected = _expect_protocol_error(() ->
        _first_use_attestation(spec, first(arms), :first_use,
            (new_process=true, no_prior_case_execution=true, no_prior_ir_probe=true)))
    return (passed=true, independent_samples=length(screen.samples), no_op_rejected,
        disconnected_native_rejected, parity_rejected, no_attestation_rejected,
        warm_process_cold_claim_rejected,
        qualification=:measurement_protocol_only_not_backend_or_scientific_validation)
end

end
