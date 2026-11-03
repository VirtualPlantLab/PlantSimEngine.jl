# Include this driver in the isolated app's Kaimon session. These are warm Julia
# JIT comparisons; neither boundary measures JuliaC executable performance.
isdefined(Main, :ReusableProgram) || include(joinpath(@__DIR__, "app", "src", "program.jl"))
isdefined(Main, :FullXPalmFixture) || include(joinpath(@__DIR__, "app", "src", "full_xpalm_fixture.jl"))
isdefined(Main, :FullXPalmChecks) || include(joinpath(@__DIR__, "full_xpalm_checks.jl"))

module FullXPalmPerformance

using Statistics
using TOML
using PlantSimEngine
using XPalm
import MultiScaleTreeGraph as MTG
import ..ReusableProgram as RP
import ..FullXPalmFixture as XF
import ..FullXPalmChecks as XC
const PSE = PlantSimEngine

function _git(directory, arguments...)
    try
        return strip(read(Cmd(["git", "-C", directory, arguments...]), String))
    catch
        return missing
    end
end

function _metadata()
    root = normpath(joinpath(@__DIR__, "..", ".."))
    manifest_path = joinpath(@__DIR__, "app", "Manifest.toml")
    manifest = TOML.parsefile(manifest_path)
    xpalm = only(manifest["deps"]["XPalm"])
    dirty = _git(root, "status", "--porcelain")
    return (
        compiler="warm Julia JIT; not a JuliaC/AOT measurement",
        julia=string(VERSION), plant_sim_engine=string(Base.pkgversion(PSE)),
        xpalm=string(Base.pkgversion(XPalm)), xpalm_manifest_revision=get(xpalm, "repo-rev", missing),
        active_project=Base.active_project(), plant_sim_engine_source=pathof(PSE), xpalm_source=pathof(XPalm),
        source_revision=_git(root, "rev-parse", "HEAD"),
        source_dirty=ismissing(dirty) ? missing : !isempty(dirty),
        cpu=Sys.CPU_NAME, machine=Sys.MACHINE, julia_threads=Threads.nthreads(),
        manifest=manifest_path,
    )
end

# Palm construction and model_applications belong to scientific authoring and
# are excluded from both measured boundaries. Do not use XF.ordinary here: it
# additionally extracts the prototype's topology and initial-value schemas.
function _regular_source(settings)
    palm = XF.palm(; settings...)
    return (palm=palm, applications=XF.specs(palm))
end

function _regular_prepared(source, context)
    model = XF.scene(source.palm, context.forcing; applications=source.applications)
    return PSE.run!(model; steps=0, outputs=context.retain ? :all : :none,
        constants=context.constants)
end

function _regular_steps!(simulation, days)
    for _ in 1:days
        PSE.step!(simulation)
    end
    return simulation
end

function _regular_setup_run(source, context)
    model = XF.scene(source.palm, context.forcing; applications=source.applications)
    return PSE.run!(model; steps=context.days, outputs=context.retain ? :all : :none,
        constants=context.constants)
end

function _typed_prepared(context)
    setup = context.setup
    # instantiate owns a private copy of every mutable model parameter/RNG.
    return RP.instantiate(context.program, setup.models, XC.native_tree(setup.topology);
        initial=setup.initial.templates, objects=setup.initial.objects, retain=context.retain)
end

function _typed_steps!(state, forcing, constants)
    for row in forcing
        RP.step!(state, row; constants)
    end
    return state
end

function _typed_setup_run(context)
    state = _typed_prepared(context)
    return _typed_steps!(state, context.forcing, context.constants)
end

function _topology(nodes)
    result = [let parent = MTG.parent(node)
        (id=MTG.node_id(node), parent=isnothing(parent) ? nothing : MTG.node_id(parent),
            category=MTG.symbol(node), link=MTG.link(node), index=MTG.index(node),
            level=MTG.scale(node), children=MTG.node_id.(MTG.children(node)))
    end for node in nodes]
    return sort!(result; by=row -> row.id)
end

function _observations(simulation::PSE.Simulation, variables, retain)
    model = PSE.runtime_model(simulation)
    nodes = [PSE.source_node(model, object.id) for object in PSE.model_objects(model)]
    return (
        objects=XF.fingerprint(model, variables), topology=_topology(nodes),
        rng=XF.rng_fingerprint(XF.models(model.applications)),
        samples=retain ? XC.ordinary_samples(simulation) : nothing,
        steps=PSE.current_step(simulation),
    )
end

function _observations(state::RP.FullState, variables, retain)
    samples = XC.native_samples(state)
    retain || isempty(samples) || error("typed retain=false unexpectedly retained samples")
    return (
        objects=XC.snapshot(state, variables), topology=_topology(values(state.nodes)),
        rng=XF.rng_fingerprint(map(application -> application.model, state.applications)),
        samples=retain ? samples : nothing, steps=state.step,
    )
end

function _validate(result, context, expected)
    actual = _observations(result, context.setup.variables, context.retain)
    actual.steps == context.days || error("incorrect final timestep")
    XC._equal(actual.objects, expected.objects) || error("canonical scientific state mismatch")
    XC._equal(actual.topology, expected.topology) || error("full MTG topology mismatch")
    isequal(actual.rng, expected.rng) || error("owned model RNG mismatch")
    if context.retain
        Set(keys(actual.samples)) == Set(keys(expected.samples)) || error("retained output keys mismatch")
        for key in keys(expected.samples)
            XC._equal(actual.samples[key], expected.samples[key]) ||
                error("retained output value mismatch at $(key)")
        end
    end
    return nothing
end

# Return only scalar measurements; the full result stays live until validation
# finishes outside @timed, and does not escape this function.
function _trial(boundary, arm, context, expected, trial)
    if arm === :regular
        source = _regular_source(context.settings)
        if boundary === :prepared_steps
            simulation = _regular_prepared(source, context)
            GC.gc()
            measured = @timed _regular_steps!(simulation, context.days)
        else
            GC.gc()
            measured = @timed _regular_setup_run(source, context)
        end
    elseif arm === :typed
        if boundary === :prepared_steps
            state = _typed_prepared(context)
            GC.gc()
            measured = @timed _typed_steps!(state, context.forcing, context.constants)
        else
            GC.gc()
            measured = @timed _typed_setup_run(context)
        end
    else
        error("unknown benchmark arm")
    end
    _validate(measured.value, context, expected)
    return (trial=trial, boundary=boundary, arm=arm,
        time_s=measured.time, bytes=measured.bytes, gc_s=measured.gctime)
end

function _summary(trials, boundary, arm)
    selected = filter(row -> row.boundary === boundary && row.arm === arm, trials)
    return (
        median_s=median(row.time_s for row in selected), min_s=minimum(row.time_s for row in selected),
        median_bytes=median(row.bytes for row in selected), min_bytes=minimum(row.bytes for row in selected),
        median_gc_s=median(row.gc_s for row in selected), min_gc_s=minimum(row.gc_s for row in selected),
    )
end

function _boundary_summary(trials, boundary)
    regular = _summary(trials, boundary, :regular)
    typed = _summary(trials, boundary, :typed)
    return (regular=regular, typed=typed,
        regular_over_typed_median=regular.median_s / typed.median_s)
end

"""
    compare_warm(; days=12, rate=0.3, reproductive=true, retain=true, repeats=7)

Compare the original complete architecture=false XPalm graph in ordinary PSE
and the reusable typed runtime, both under the current Julia JIT compiler.
This does not measure JuliaC/AOT speed, process startup, authoring, output
serialization, or compilation of the reusable program.

`prepared_steps` times only daily advancement. Both simulations, bindings,
output policies and forcing are prepared before the timer.

`setup_and_steps` starts from scientifically authored inputs prepared outside
the timer. Ordinary PSE includes Weather conversion, MTG/status import,
scenario compilation and execution. The typed arm includes empty-attribute MTG
reconstruction, private-model/RNG instantiation and execution; its immutable
program and typed initial templates are reused. Common plain forcing rows are
prepared once outside both boundaries.

Each arm uses a fresh state for every sample, with GC before and validation
after timing. A canonical-state/topology/output/RNG oracle is built outside
timing; both exact boundary paths then get one unrecorded warmup. Retained
sample key/value parity is checked with `retain=true`. With `retain=false`,
canonical state, topology and RNG still match, but internal temporal-history
retention differs between implementations and is not compared as output.

The returned object contains scalar trials and median/minimum summaries only.
The separately reported one-time authoring/preparation observations may include
first-use JIT compilation and are not part of either warm comparison.
"""
function compare_warm(; days=12, rate=0.3, reproductive=true, retain=true, repeats=7)
    days isa Integer && days > 0 || throw(ArgumentError("days must be positive"))
    repeats isa Integer && repeats > 0 || throw(ArgumentError("repeats must be positive"))
    isfinite(rate) && rate >= 0 || throw(ArgumentError("rate must be finite and nonnegative"))
    retain isa Bool || throw(ArgumentError("retain must be Bool"))
    settings = (; rate, reproductive)
    metadata = _metadata()
    authored = @timed XF.authoring(; settings...)
    setup = authored.value
    prepared = @timed RP.prepare(XF.preparation_scene(setup); initial=setup.initial.templates)
    context = (settings=settings, setup=setup, program=prepared.value,
        forcing=XF.rows(days), constants=PSE.Constants(), days=Int(days), retain=retain)
    caller_rng = XF.rng_fingerprint(setup.models)

    # Build the independent ordinary oracle without retaining its Simulation.
    expected = let source = _regular_source(settings)
        simulation = _regular_prepared(source, context)
        _regular_steps!(simulation, context.days)
        _observations(simulation, setup.variables, retain)
    end
    expected.steps == context.days || error("incorrect oracle timestep")

    trials = NamedTuple[]
    for boundary in (:prepared_steps, :setup_and_steps)
        # Validate/warm each exact measured path before recording any trials.
        _trial(boundary, :regular, context, expected, 0)
        _trial(boundary, :typed, context, expected, 0)
        for trial in 1:repeats
            order = isodd(trial) ? (:regular, :typed) : (:typed, :regular)
            for arm in order
                push!(trials, _trial(boundary, arm, context, expected, trial))
            end
        end
    end
    isequal(XF.rng_fingerprint(setup.models), caller_rng) || error("caller-owned RNG was mutated")
    return (
        metadata=metadata, settings=(days=days, rate=rate, reproductive=reproductive,
            retain=retain, repeats=repeats, architecture=false),
        validated=(objects=length(expected.objects), applications=length(setup.applications),
            retained_samples=retain ? length(expected.samples) : 0,
            canonical_state=true, full_topology=true, owned_rng=true,
            retained_sample_parity=retain),
        one_time=(authoring_s=authored.time, authoring_bytes=authored.bytes,
            program_preparation_s=prepared.time, program_preparation_bytes=prepared.bytes,
            includes_first_use_compilation=true),
        prepared_steps=_boundary_summary(trials, :prepared_steps),
        setup_and_steps=_boundary_summary(trials, :setup_and_steps),
        trials=trials,
    )
end

end # module FullXPalmPerformance
