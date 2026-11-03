# Include and run only through the isolated app's Kaimon session. Explicit
# performance-module arguments keep old/current prepared runtimes independent.
module XPalmScaling

using Statistics
using SHA
using TOML
using XPalm

const SampleKey = Tuple{Symbol,Int,Int,Symbol}
const ARM_LABELS = (:ordinary_pse, :previous_prepared_bf4c3ab7, :current_prepared)

function _parameters(fixture, profile, rate, reproductive)
    profile === :accelerated && return fixture.parameters(; rate, reproductive)
    profile === :package_defaults && return XPalm.default_parameters()
    throw(ArgumentError("profile must be :accelerated or :package_defaults"))
end

function _source(performance, settings)
    parameters = _parameters(performance.XF, settings.profile, settings.rate, settings.reproductive)
    palm = XPalm.Palm(; initiation_age=0, parameters, architecture=false)
    return (palm=palm, applications=performance.XF.specs(palm))
end

function _profile_metadata(fixture, settings)
    p = _parameters(fixture, settings.profile, settings.rate, settings.reproductive)
    return (name=settings.profile, package_parameters_untouched=settings.profile === :package_defaults,
        initiation_age=0, architecture=false, forcing="FullXPalmFixture.rows synthetic daily forcing",
        phyllochron_initial=p["phyllochron"]["production_speed_initial"],
        phyllochron_mature=p["phyllochron"]["production_speed_mature"],
        flowering=p["phenology"]["inflorescence"]["TT_flowering"],
        abortion_duration=p["phenology"]["inflorescence"]["duration_abortion"],
        sex_duration=p["phenology"]["inflorescence"]["duration_sex_determination"],
        sex_seed=p["reproduction"]["sex_ratio"]["random_seed"],
        abortion_seed=p["reproduction"]["abortion"]["random_seed"])
end

_prepare_current(performance, setup) =
    performance.RP.prepare(performance.XF.preparation_scene(setup); initial=setup.initial.templates)

# Historical source snapshots predate the CompositeModel authoring entry.
_prepare_historical(performance, setup) =
    performance.RP.prepare(setup.applications; initial=setup.initial.templates)

function _context(prepare, performance, settings)
    source = _source(performance, settings)
    xf = performance.XF
    setup = (palm=source.palm, applications=source.applications,
        models=xf.models(source.applications), topology=xf.topology_descriptor(source.palm),
        variables=xf.variables_by_category(source.palm, source.applications),
        initial=xf.initial_data(source.palm, source.applications))
    program = prepare(performance, setup)
    return (settings=settings, setup=setup, program=program, days=settings.days, retain=settings.retain)
end

_runtime_model(model, settings) = model
function _runtime_model(model::XPalm.Models.PhyllochronModel, settings)
    settings.profile === :package_defaults && return model
    return XPalm.Models.PhyllochronModel(model.age_palm_maturity, settings.rate, settings.rate)
end

# The fixed-size model projection, Constants and forcing construction match
# what native simulate_full_xpalm includes. The actual step loop remains in
# each performance module's existing concrete typed execution boundary.
function _typed_run(performance, context)
    models = performance.RP._schema_map(model -> _runtime_model(model, context.settings), context.setup.models)
    setup = merge(context.setup, (models=models,))
    running = merge(context, (setup=setup, forcing=performance.XF.rows(context.days),
        constants=performance.PSE.Constants()))
    return performance._typed_setup_run(running)
end

function _ordinary_run(performance, context, source)
    running = merge(context, (forcing=performance.XF.rows(context.days), constants=performance.PSE.Constants()))
    return performance._regular_setup_run(source, running)
end

function _each_sample(f, performance, result, typed)
    if typed
        for application in result.applications, (variable, stream) in pairs(application.streams), sample in stream.retained
            f((sample.application, sample.object_id, sample.step, variable), sample.value)
        end
    else
        # Avoid collect_outputs' row materialization and per-sample TestSets.
        for ((application, id, variable), samples) in result.temporal_streams, (time, value) in samples
            f((application, performance.PSE.ObjectId(id).value, Int(round(time)), variable), value)
        end
    end
    return nothing
end

function _state_observations(performance, result, variables, typed)
    if typed
        return (objects=performance.XC.snapshot(result, variables),
            topology=performance._topology(values(result.nodes)),
            rng=performance.XF.rng_fingerprint(map(app -> app.model, result.applications)), steps=result.step)
    end
    model = performance.PSE.runtime_model(result)
    nodes = [performance.PSE.source_node(model, object.id) for object in performance.PSE.model_objects(model)]
    return (objects=performance.XF.fingerprint(model, variables), topology=performance._topology(nodes),
        rng=performance.XF.rng_fingerprint(performance.XF.models(model.applications)),
        steps=performance.PSE.current_step(result))
end

function _oracle(performance, context, max_reachable_bytes)
    result = _ordinary_run(performance, context, _source(performance, context.settings))
    reachable_bytes = Base.summarysize(result)
    _memory_gate(reachable_bytes, max_reachable_bytes, :ordinary_pse)
    observations = _state_observations(performance, result, context.setup.variables, false)
    samples = Dict{SampleKey,Any}()
    if context.retain
        _each_sample(performance, result, false) do key, value
            haskey(samples, key) && error("duplicate ordinary retained sample key")
            samples[key] = performance.XC._plain(value)
        end
    end
    native_rng = Dict{Tuple{Symbol,Symbol},NTuple{4,UInt64}}()
    for application in performance.PSE.runtime_model(result).applications
        for field in (:rng, :random_generator)
            hasfield(typeof(application.model), field) || continue
            probe = copy(getfield(application.model, field))
            native_rng[(application.name, field)] = ntuple(_ -> XPalm.Random.rand(probe, UInt64), 4)
        end
    end
    return merge(observations, (samples=samples, reachable_bytes=reachable_bytes, native_rng=native_rng))
end

function _validate(performance, result, context, expected, typed)
    actual = _state_observations(performance, result, context.setup.variables, typed)
    actual.steps == context.days || error("final timestep mismatch")
    performance.XC._equal(actual.objects, expected.objects) || error("canonical scientific state mismatch")
    performance.XC._equal(actual.topology, expected.topology) || error("ordered topology mismatch")
    isequal(actual.rng, expected.rng) || error("owned RNG mismatch")
    if context.retain
        seen = Set{SampleKey}()
        _each_sample(performance, result, typed) do key, value
            key in seen && error("duplicate retained sample key")
            haskey(expected.samples, key) || error("unexpected retained sample key")
            performance.XC._equal(value, expected.samples[key]) || error("retained sample value mismatch at $key")
            push!(seen, key)
        end
        length(seen) == length(expected.samples) || error("missing retained samples")
    elseif typed
        all(app -> all(stream -> isempty(stream.retained), values(app.streams)), result.applications) ||
            error("retain=false produced retained typed samples")
    end
    return nothing
end

function _memory_gate(bytes, limit, arm)
    isnothing(limit) || bytes <= limit || error("$arm reachable state exceeds max_reachable_bytes ($bytes > $limit)")
    return nothing
end

function _typed_memory(performance, context, expected, limit, arm)
    result = _typed_run(performance, context)
    _validate(performance, result, context, expected, true)
    bytes = Base.summarysize(result)
    _memory_gate(bytes, limit, arm)
    return bytes
end

function _trial(performance, context, expected, arm, trial)
    if arm === :ordinary_pse
        source = _source(performance, context.settings)
        GC.gc()
        measured = @timed _ordinary_run(performance, context, source)
    else
        GC.gc()
        measured = @timed _typed_run(performance, context)
    end
    _validate(performance, measured.value, context, expected, arm !== :ordinary_pse)
    return (trial=trial, arm=arm, time_s=measured.time, bytes=measured.bytes, gc_s=measured.gctime)
end

function _summary(trials, arm)
    rows = filter(row -> row.arm === arm, trials)
    return (median_s=median(row.time_s for row in rows), min_s=minimum(row.time_s for row in rows),
        median_bytes=median(row.bytes for row in rows), min_bytes=minimum(row.bytes for row in rows),
        median_gc_s=median(row.gc_s for row in rows), min_gc_s=minimum(row.gc_s for row in rows))
end

function _source_hashes(root)
    isnothing(root) && return nothing
    files = ("program.jl", "cohort_program.jl", "full_program_plan.jl", "full_program_runtime.jl", "full_program_bindings.jl", "full_program_history.jl")
    return Dict(file => bytes2hex(sha256(read(joinpath(root, "app", "src", file)))) for file in files)
end

"""
    compare_scaling(previous, current; days=256, profile=:accelerated,
                    rate=0.3, reproductive=true, retain=false, repeats=3, ...)

`previous` and `current` are independently loaded FullXPalmPerformance modules,
for example `Main.CV.BeforeReuse.FullXPalmPerformance` and
`Main.DV.FullXPalmPerformance`. Every case benchmarks ordinary PSE, previous
prepared bf4c3ab7, and current prepared execution with the same inputs. Modules
must already be loaded through Kaimon; this driver never starts Julia.
Pass `nothing` for `previous` to measure ordinary PSE and the current executor
without the optional historical prepared arm. Ordinary PSE is always included.

The fresh-simulation boundary includes forcing/Constants construction plus
ordinary scene/run! or typed runtime model projection/MTG/state instantiation
and daily execution. Scientific Palm/spec authoring and reusable preparation,
explicit GC and full parity checks are outside timers. Arms rotate/reverse
order between trials after one validated warmup each. Return only scalar
timings/bytes/GC, reachable state sizes (not peak RSS), work counts and metadata.

`:package_defaults` passes XPalm.default_parameters() untouched to the Palm
constructor, preserving unequal initial/mature phyllochron endpoints and RNG
defaults. `rate`/`reproductive` are ignored for that profile. Architecture=false,
initiation_age=0 and synthetic qualification weather remain explicit scenario
choices; this is not a calibrated field trajectory or all XPalm defaults.

Start progressively with 256/512/1024 days without retention. Retained-output
cases are bounded to <=256 days; `max_reachable_bytes` optionally rejects a
completed preflight state before timed trials, and cannot prevent that first
state's allocation. Do not run long retained trajectories as an exploratory
default. `repeats` must be 3–7. Run serially on an otherwise idle host.

An optional `native_bundle` adds current JuliaC safe results using the same
full native schema and an explicitly supplied `native_checks` module. The
existing perffull entry supports only :accelerated; package defaults need a
matching separately built entry and explicit `native_command` factory. See
`_native_scaling` for its signature. No unsupported native result is invented.
"""
function compare_scaling(previous, current; days=256, profile=:accelerated,
                         rate=0.3, reproductive=true, retain=false, repeats=3,
                         max_reachable_bytes=nothing, previous_source_root=nothing,
                         current_source_root=@__DIR__, native_bundle=nothing,
                         native_checks=nothing, native_command=nothing, native_launches=3)
    days isa Integer && days > 0 || throw(ArgumentError("days must be positive"))
    repeats isa Integer && 3 <= repeats <= 7 || throw(ArgumentError("repeats must be 3–7"))
    reproductive isa Bool && retain isa Bool || throw(ArgumentError("reproductive/retain must be Bool"))
    retain && days > 256 && throw(ArgumentError("retained-output scaling cases are bounded to <=256 days"))
    settings = (; days=Int(days), profile, rate, reproductive, retain)
    profile_metadata = _profile_metadata(current.XF, settings)
    arms = isnothing(previous) ? (:ordinary_pse, :current_prepared) : ARM_LABELS
    before = isnothing(previous) ? nothing : _context(_prepare_historical, previous, settings)
    after = _context(_prepare_current, current, settings)
    previous_rng = isnothing(previous) ? nothing : previous.XF.rng_fingerprint(before.setup.models)
    current_rng = current.XF.rng_fingerprint(after.setup.models)
    expected = _oracle(current, after, max_reachable_bytes)
    previous_memory = isnothing(previous) ? nothing : _typed_memory(previous, before, expected, max_reachable_bytes, ARM_LABELS[2])
    current_memory = _typed_memory(current, after, expected, max_reachable_bytes, ARM_LABELS[3])
    warmups = NamedTuple[]
    for arm in arms
        perf, ctx = arm === ARM_LABELS[2] ? (previous, before) : (current, after)
        push!(warmups, _trial(perf, ctx, expected, arm, 0))
    end
    trials = NamedTuple[]
    for trial in 1:repeats
        order = circshift(collect(arms), mod(trial - 1, length(arms)))
        iseven(trial) && reverse!(order)
        for arm in order
            perf, ctx = arm === ARM_LABELS[2] ? (previous, before) : (current, after)
            push!(trials, _trial(perf, ctx, expected, arm, trial))
        end
    end
    isnothing(previous) || isequal(previous.XF.rng_fingerprint(before.setup.models), previous_rng) || error("previous caller RNG mutated")
    isequal(current.XF.rng_fingerprint(after.setup.models), current_rng) || error("current caller RNG mutated")
    native = _native_scaling(native_bundle, native_checks, current, after, expected;
        command_factory=native_command, repeats, launches=native_launches)
    categories = Dict{Symbol,Int}()
    for object in expected.objects
        categories[object.scale] = get(categories, object.scale, 0) + 1
    end
    return (settings=settings, profile=profile_metadata,
        scope="Fresh simulation including forcing/Constants; scientific authoring/program preparation/explicit GC/validation excluded",
        metadata=(current=current._metadata(), previous_module=string(previous), current_module=string(current),
            previous_runtime_source_sha256=_source_hashes(previous_source_root),
            current_runtime_source_sha256=_source_hashes(current_source_root)),
        work=(days=days, initial_objects=length(after.setup.topology), final_objects=length(expected.objects),
            objects_by_category=categories, applications=length(after.setup.applications), retained_samples=length(expected.samples)),
        validated=(canonical_state=true, ordered_topology=true, owned_rng=true, retained_sample_parity=retain),
        ordinary_pse=_summary(trials, ARM_LABELS[1]), previous_prepared_bf4c3ab7=isnothing(previous) ?
            (supported=false, reason="historical prepared arm not selected; ordinary PSE baseline retained") : _summary(trials, ARM_LABELS[2]),
        current_prepared=_summary(trials, ARM_LABELS[3]), current_juliac_safe=native,
        reachable_state_bytes=(ordinary_pse=expected.reachable_bytes,
            previous_prepared_bf4c3ab7=previous_memory, current_prepared=current_memory), warmups=warmups, trials=trials)
end

include("xpalm_scaling_native.jl")

end # module XPalmScaling
