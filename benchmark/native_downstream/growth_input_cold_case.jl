module GrowthInputColdCase

# Definitions only at load. Call run_growth_input_cold_case once in each fresh
# Kaimon worker; package/helper import is outside the measured case.
using PlantSimEngine, SHA
const PSE = PlantSimEngine
const COLD_COUNT = Ref(0)

export current_source_image, run_growth_input_cold_case

const IMAGE_FILES = (
    "Project.toml", "Manifest.toml",
    "src/composite_model/compilation.jl",
    "src/composite_model/runtime_outputs.jl",
    "src/composite_model/environment_bindings.jl",
    "benchmark/native_downstream/load_experiments.jl",
    "benchmark/native_downstream/load_direct_planner_experiment.jl",
    "benchmark/native_downstream/direct_planner_fixtures.jl",
    "benchmark/native_downstream/direct_planner_measurements.jl",
    "benchmark/native_downstream/bounded_preparation.jl",
    "benchmark/native_downstream/planner_boundaries.jl",
    "benchmark/native_downstream/growth_input_reuse.jl",
    "benchmark/native_downstream/growth_plan_storage.jl",
    "benchmark/native_downstream/growth_input_measurements.jl",
    "benchmark/native_downstream/growth_input_cold_case.jl",
)

"""Source-byte fingerprint only; performs no simulation, kernel or IR probe.

Prefer constructing this expected image outside Julia before starting the fresh
worker. Calling this definition-only fingerprint helper also executes no model
or planner code.
"""
current_source_image(root=pkgdir(PSE)) = Dict(path => bytes2hex(sha256(read(joinpath(root, path))))
    for path in IMAGE_FILES)

function _check_image(root, expected)
    all(path -> haskey(expected, path), IMAGE_FILES) ||
        error("Expected source image must cover every cold helper/core/prototype input")
    actual = Dict{String,String}()
    for (relative, digest) in pairs(expected)
        relative = String(relative)
        isabspath(relative) && error("Use project-relative source-image paths")
        path = normpath(joinpath(root, relative))
        startswith(path, abspath(root) * "/") || error("Source image escaped the expected project")
        actual[relative] = bytes2hex(sha256(read(path)))
        actual[relative] == digest || error("Cold source image changed: $relative")
    end
    return actual
end

function _load_definitions(root)
    native = joinpath(root, "benchmark", "native_downstream")
    isdefined(Main, :DirectPlannerMeasurements) ||
        Base.include(Main, joinpath(native, "load_direct_planner_experiment.jl"))
    for (name, file) in ((:GrowthInputReuse, "growth_input_reuse.jl"),
        (:GrowthPlanStorage, "growth_plan_storage.jl"),
        (:GrowthInputMeasurements, "growth_input_measurements.jl"))
        isdefined(Main, name) || Base.include(Main, joinpath(native, file))
    end
    # Method-file checks examine definitions, never scientific IR or instances.
    for (name, entry, file) in ((:DirectPlannerMeasurements, :prepare_arm, "direct_planner_measurements.jl"),
        (:GrowthInputMeasurements, :prepare_growth_input_arm, "growth_input_measurements.jl"),
        (:GrowthPlanStorage, :enable_growth_plan_storage!, "growth_plan_storage.jl"))
        method = first(methods(getfield(getfield(Main, name), entry)))
        realpath(String(method.file)) == realpath(joinpath(native, file)) ||
            error("Cold helper loaded a prototype from a different source image")
    end
    return nothing
end

Base.@nospecializeinfer @noinline function _case(kind::Symbol, arm::Symbol, freshness,
    progress_path, expected_digest)
    H = Main.DirectPlannerMeasurements
    G = Main.GrowthInputMeasurements
    F = Main.DirectPlannerFixtures
    CR = Main.CompiledRegionsExperiment
    policy = G.growth_input_policies(arm)
    config = merge(H.construct_config(kind; steps=2, nobjects=2, additions=3,
        seed=1, emission_speed=0.2, outputs=:none), (policies=policy,))
    phases = Dict{Symbol,Any}()
    H._stage(progress_path, kind, arm, "before_construction")
    measured = H._timed(F.construct_fixture, kind, config)
    fixture = measured.value
    phases[:construction] = H._phase(measured)
    H._stage(progress_path, kind, arm, "after_construction")
    H._stage(progress_path, kind, arm, "before_preparation")
    measured = H._timed(G.prepare_growth_input_arm, fixture.model, arm; outputs=:none)
    simulation = measured.value
    phases[:preparation] = H._phase(measured)
    H._stage(progress_path, kind, arm, "after_preparation")
    H._stage(progress_path, kind, arm, "before_first_execution")
    measured = H._timed(PSE.step!, simulation)
    phases[:first_execution] = H._phase(measured)
    H._stage(progress_path, kind, arm, "after_first_execution")
    H._stage(progress_path, kind, arm, "before_remaining_execution")
    measured = H._timed(PSE.continue!, simulation; steps=1)
    phases[:remaining_execution] = H._phase(measured)
    H._stage(progress_path, kind, arm, "after_remaining_execution")
    H._stage(progress_path, kind, arm, "before_diagnostics")
    observed = (state=Base.invokelatest(F.snapshot, simulation, kind),
        scientific_rngs=Base.invokelatest(F.scientific_rngs, simulation.model))
    digest = bytes2hex(sha256(repr(observed)))
    expected_digest === nothing || digest == expected_digest || error("Cold scientific digest differs")
    coverage = Base.invokelatest(G.growth_input_coverage, simulation, arm, kind)
    work = Base.invokelatest(CR.downstream_work_report, simulation, fixture.initial_ids)
    H._stage(progress_path, kind, arm, "after_diagnostics")
    return (; config, arm, policies=policy, freshness, pid=getpid(), julia=string(VERSION),
        source=Base.pathof(PSE), phases,
        complete_seconds=sum(row.seconds for row in values(phases)),
        complete_allocated_bytes=sum(row.allocated_bytes for row in values(phases)),
        digest, snapshot=observed, coverage, work,
        forcing_setup=:XP_weather_IO_inside_measured_constructor,
        diagnostics=:after_all_timed_execution, temperature=:first_use)
end

"""One fresh first-use sample; never call this after a warm/check/profile run.

The caller must attest a new unrun worker and supply expected source hashes.
Loader/import costs are separate from construction/preparation/first/remaining
execution. Every model/forcing/tree/RNG is newly constructed; no shared weather
is passed, so original XP weather I/O belongs to the constructor phase.
Writes full evidence to output_path and returns a small receipt only.
"""
function run_growth_input_cold_case(kind::Symbol=:xp, arm::Symbol=:bounded_preparation;
    freshness, expected_source_hashes, output_path,
    root=pkgdir(PSE), expected_source=joinpath(root, "src", "PlantSimEngine.jl"),
    expected_project=joinpath(root, "Project.toml"), expected_digest=nothing,
    external_import_seconds=nothing)
    kind in (:pb, :xp) || error("Start cold comparisons with the tiny PB or XP fixture")
    all(name -> hasproperty(freshness, name) && getproperty(freshness, name) === true,
        (:new_process, :no_prior_case_execution, :no_prior_ir_probe)) || error("Invalid cold freshness attestation")
    hasproperty(freshness, :pid) && freshness.pid == getpid() || error("Attest this worker PID")
    hasproperty(freshness, :previous_pid) && freshness.previous_pid == getpid() &&
        error("Cold comparison reused the previous worker")
    iszero(COLD_COUNT[]) || error("One cold sample per fresh worker")
    realpath(Base.pathof(PSE)) == realpath(expected_source) || error("Unexpected loaded PSE source")
    realpath(pkgdir(PSE)) == realpath(root) || error("Unexpected loaded PSE project")
    realpath(Base.active_project()) == realpath(expected_project) || error("Unexpected active Julia project")
    image = _check_image(root, expected_source_hashes)
    COLD_COUNT[] += 1
    loader = @timed Base.invokelatest(_load_definitions, root)
    H, M = Main.DirectPlannerMeasurements, Main.NativeDownstreamMeasurements
    iszero(H.COLD_COUNT[]) && iszero(M.MEASUREMENT_COUNT[]) && isempty(M.FIRST_USE_RECORDS) ||
        error("A shared harness case already ran in this worker")
    H.COLD_COUNT[] += 1
    M.MEASUREMENT_COUNT[] += 1
    progress_path = output_path * ".pid$(getpid()).stages.tsv"
    record = Base.invokelatest(_case, kind, arm, freshness, progress_path, expected_digest)
    # The definition loader creates these Main bindings after this helper's
    # world. Enter the latest world before resolving the bindings themselves,
    # not only before calling the provenance function.
    provenance = Base.invokelatest() do
        Main.NativeDownstreamMeasurements.process_provenance(
            packages=(PSE, Main.PlantBiophysics, Main.XPalm, Main.PlantGeom),
        )
    end
    _check_image(root, expected_source_hashes) == image || error("Source drift during the cold case")
    mkpath(dirname(abspath(output_path)))
    open(output_path, "w") do io
        PSE.JSON.print(io, (loader_seconds=loader.time,
            loader_scope=:definition_loader_after_PSE_and_cold_helper_import,
            external_import_seconds, record, provenance, source_image=image,
            freshness_verification=:caller_attestation_plus_helper_and_existing_harness_counters), 2)
    end
    return (kind, arm, pid=getpid(), output_path, digest=record.digest,
        complete_seconds=record.complete_seconds, source_files_verified=length(image),
        loader_seconds=loader.time)
end

end # module
