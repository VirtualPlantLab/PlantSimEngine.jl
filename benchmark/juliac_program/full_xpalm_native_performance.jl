# Include through Kaimon in the isolated app environment. Only already-built
# native executables are launched by measure_native; no Julia CLI is started.
isdefined(Main, :FullXPalmNativeChecks) || include(joinpath(@__DIR__, "full_xpalm_native_checks.jl"))

module FullXPalmNativePerformance

using Statistics
using Test
using TOML
using SHA
import ..FullXPalmNativeChecks as NC

# Keep this instrumentation identical to the temporary timing build used for
# the initial measurements. Printing and explicit GC remain outside the timer.
const PERF_HELPER = raw"""
# Temporary measurement entry: complete simulation only, no text serialization
# inside the timer. Last result is printed afterwards for parity verification.
Base.@noinline function _perf_full_trial(i::Int,days::Int,rate::Float64,reproductive::Bool,retain::Bool,show_result::Bool)
    GC.gc()
    start=time_ns()
    state=simulate_full_xpalm(days,rate,reproductive;retain=retain)
    elapsed=time_ns()-start
    _full_print_record(("P",i,elapsed,length(state.nodes),state.step))
    show_result && _print_full_xpalm(state)
    return nothing
end

"""

const PERF_BRANCH = raw"""
    if mode=="perffull"
        length(args)==6 || throw(ArgumentError("perffull days rate reproductive repeats retain"))
        days=parse(Int,args[2]); rate=parse(Float64,args[3]); reproduction=parse(Bool,args[4])
        repeats=parse(Int,args[5]); retain=parse(Bool,args[6])
        repeats>0 || throw(ArgumentError("positive repeats required"))
        for i in 0:repeats
            _perf_full_trial(i,days,rate,reproduction,retain,i==repeats)
        end
        return 0
    end
"""

function _within(path, parent)
    relative = relpath(abspath(path), abspath(parent))
    return relative == "." || (!isabspath(relative) && first(splitpath(relative)) != "..")
end

function _fresh_destination(path, source_app, standard_build)
    path = abspath(path)
    (_within(path, source_app) || _within(source_app, path) ||
        _within(path, standard_build) || _within(standard_build, path)) &&
        error("performance build destinations must be separate from the standard app/build")
    ispath(path) && error("performance build destination already exists: $path")
    return path
end

function _rebase_paths!(app, original)
    project_path = joinpath(app, "Project.toml")
    project = TOML.parsefile(project_path)
    for source in values(get(project, "sources", Dict()))
        haskey(source, "path") || continue
        source["path"] = abspath(joinpath(original, source["path"]))
    end
    open(project_path, "w") do io
        TOML.print(io, project)
    end
    manifest_path = joinpath(app, "Manifest.toml")
    manifest = TOML.parsefile(manifest_path)
    for entries in values(manifest["deps"]), entry in entries
        haskey(entry, "path") || continue
        entry["path"] = abspath(joinpath(original, entry["path"]))
    end
    open(manifest_path, "w") do io
        TOML.print(io, manifest)
    end
    return nothing
end

function _instrument!(app)
    entry = joinpath(app, "src", "PSEProgramApp.jl")
    source = read(entry, String)
    occursin("_perf_full_trial", source) && error("source app is already instrumented")
    main_marker = "function (@main)(args::Vector{String})"
    mode_marker = "    mode = args[1]\n"
    length(findall(main_marker, source)) == 1 || error("cannot identify the unique native main entry")
    length(findall(mode_marker, source)) == 1 || error("cannot identify the unique mode parser")
    source = replace(source, main_marker => PERF_HELPER * main_marker; count=1)
    source = replace(source, mode_marker => mode_marker * PERF_BRANCH; count=1)
    write(entry, source)
    return entry
end

function _source_revision(root)
    try
        return strip(read(Cmd(["git", "-C", root, "rev-parse", "HEAD"]), String))
    catch
        return "unknown"
    end
end

"""
    build_native_performance(; bundle=nothing, app_directory=nothing)

Build a separate instrumented copy of the qualified app with JuliaC safe
trimming and generic CPU. The standard app, standard bundles and `latest.txt`
are never changed. By default both destinations are fresh temporary paths;
explicit destinations must not exist and must be separate from the standard
app/build and each other. The returned temporary paths remain available for
inspection, measurement and caller-controlled cleanup.

Call through Kaimon with `Main.JuliaC` already loaded. For example, in a Kaimon
session whose project and cwd are `benchmark/juliac_program/app`:

```julia
push!(LOAD_PATH, abspath("../buildenv"))
using JuliaC
include("../full_xpalm_native_performance.jl")
built = FullXPalmNativePerformance.build_native_performance()
result = FullXPalmNativePerformance.measure_native(built.bundle)
```

The copied Project/Manifest path dependencies are rebased to their original
sources. No package resolution, dependency changes, verifier hooks, arbitrary
entrypoints or diagnostic preloads are introduced. `build.toml`, the compile
log, hashes and the instrumented app are kept with the separate build evidence.
Build phase timings may include first-use JIT work and are not runtime samples.
"""
function build_native_performance(; bundle=nothing, app_directory=nothing)
    isdefined(Main, :JuliaC) || error("load JuliaC in the calling Kaimon session before building")
    juliac = getfield(Main, :JuliaC)
    source_app = joinpath(@__DIR__, "app")
    standard_build = joinpath(@__DIR__, "build")
    scratch = (isnothing(bundle) || isnothing(app_directory)) ? mktempdir(prefix="pse-native-perf-") : nothing
    destination = _fresh_destination(isnothing(bundle) ? joinpath(scratch, "bundle") : bundle,
        source_app, standard_build)
    app = _fresh_destination(isnothing(app_directory) ? joinpath(scratch, "app") : app_directory,
        source_app, standard_build)
    (_within(destination, app) || _within(app, destination)) && error("app and bundle destinations overlap")
    mkpath(dirname(app))
    cp(source_app, app)
    _rebase_paths!(app, source_app)
    entry = _instrument!(app)
    mkpath(destination)

    image = juliac.ImageRecipe(file=app, output_type="--output-exe",
        trim_mode="safe", cpu_target="generic", verbose=false, quiet=true)
    compilation_s = @elapsed open(joinpath(destination, "compile.log"), "w") do io
        redirect_stdout(io) do
            redirect_stderr(io) do
                juliac.compile_products(image)
            end
        end
    end
    link = juliac.LinkRecipe(image_recipe=image, outname=joinpath(destination, "pse_program"), rpath="@bundle")
    link_s = @elapsed juliac.link_products(link)
    bundle_s = @elapsed juliac.bundle_products(juliac.BundleRecipe(link_recipe=link, output_dir=destination))
    launcher = joinpath(destination, "bin", "run-pse-program")
    cp(joinpath(@__DIR__, "launcher.sh"), launcher; force=true)
    chmod(launcher, 0o755)
    result = (
        julia=string(VERSION), juliac=string(Base.pkgversion(juliac)),
        trim=image.trim_mode, cpu=image.cpu_target, compilation_s=compilation_s,
        link_s=link_s, bundle_s=bundle_s, bundle=destination, app_directory=app,
        performance_entry=true, source_revision=_source_revision(normpath(joinpath(@__DIR__, "..", ".."))),
        app_sha256=bytes2hex(sha256(read(entry))),
        binary_sha256=bytes2hex(sha256(read(joinpath(destination, "bin", "pse_program")))),
    )
    open(joinpath(destination, "build.toml"), "w") do io
        TOML.print(io, Dict(string(key) => value for (key, value) in pairs(result)))
    end
    return result
end

function _build_provenance(bundle)
    path = joinpath(bundle, "build.toml")
    isfile(path) || error("build the instrumented bundle with build_native_performance first")
    build = TOML.parsefile(path)
    get(build, "trim", nothing) == "safe" || error("native timings require safe trimming")
    get(build, "cpu", nothing) == "generic" || error("native timings require generic CPU")
    get(build, "binary_sha256", nothing) ==
        bytes2hex(sha256(read(joinpath(bundle, "bin", "pse_program")))) ||
        error("native binary differs from its build provenance")
    return (available=true, trim=build["trim"], cpu=build["cpu"],
        julia=get(build, "julia", missing), juliac=get(build, "juliac", missing),
        app_sha256=get(build, "app_sha256", missing))
end

"""
    measure_native(bundle; days=12, rate=0.3, reproductive=true,
                   retain=true, repeats=7, launches=3)

Launch the already-built `perffull` native mode serially. Every process performs
one P0 warmup followed by `repeats` independent simulations, with an explicit
GC before each internal timer. P0 timings are returned separately and excluded
from median/minimum summaries. Only the last simulation is serialized, after
its timer, and every launch is compared against the original PSE reference by
`FullXPalmNativeChecks`: all canonical fields, topology, retained output keys
and values, and future owned-RNG draws. With `retain=false`, the expected
retained samples are empty while canonical-state/topology/RNG checks remain.

The internal scope is `simulate_full_xpalm`: model replacement, MTG rebuilding,
private-model/RNG instantiation, Constants/forcing construction and daily
execution. It excludes startup, explicit GC, printing, host parsing and parity
checks. Scientific authoring and the immutable program are reused from build
time. This is a warm-process native measurement, not cold launch latency or a
pure compiler comparison with `FullXPalmPerformance.setup_and_steps` (which
prepares common forcing rows and Constants outside its timer).

Run on an otherwise idle host without concurrent Julia computation. Only
scalar timings and validation counts escape; native output/state is released
between launches. The bundle must come from `build_native_performance`; its
safe/generic build provenance and binary hash are checked before measuring.
"""
function measure_native(bundle; days=12, rate=0.3, reproductive=true,
                        retain=true, repeats=7, launches=3)
    days isa Integer && days > 0 || throw(ArgumentError("days must be positive"))
    repeats isa Integer && repeats > 0 || throw(ArgumentError("repeats must be positive"))
    launches isa Integer && launches > 0 || throw(ArgumentError("launches must be positive"))
    isfinite(rate) && rate >= 0 || throw(ArgumentError("rate must be finite and nonnegative"))
    reproductive isa Bool && retain isa Bool || throw(ArgumentError("reproductive and retain must be Bool"))
    bundle = abspath(bundle)
    executable = joinpath(bundle, "bin", "run-pse-program")
    isfile(executable) || error("missing native launcher $executable")
    build = _build_provenance(bundle)
    expected = NC.reference((; days, rate, reproductive))
    retain || (expected = merge(expected, (samples=empty(expected.samples),)))
    trials = NamedTuple[]
    warmups = NamedTuple[]
    validation = NamedTuple[]
    for launch in 1:launches
        command = addenv(Cmd([executable, "perffull", string(days), string(rate),
            string(reproductive), string(repeats), string(retain)]),
            "JULIA_PROJECT" => nothing, "JULIA_LOAD_PATH" => nothing)
        GC.gc()
        output = read(command, String)
        lines = split(chomp(output), '\n')
        rows = filter(line -> startswith(line, "P,"), lines)
        length(rows) == repeats + 1 || error("invalid timing sample count")
        for (index, line) in enumerate(rows)
            fields = split(line, ',')
            length(fields) == 5 || error("invalid timing record")
            parse(Int, fields[2]) == index - 1 || error("invalid trial order")
            parse(Int, fields[4]) == expected.objects || error("native object count mismatch")
            parse(Int, fields[5]) == days || error("native step mismatch")
            row = (launch=launch, trial=index - 1, time_s=parse(Int, fields[3]) * 1e-9)
            push!(index == 1 ? warmups : trials, row)
        end
        parsed = NC.parse_native(join(filter(line -> !startswith(line, "P,"), lines), '\n'))
        result = @testset "native timing result launch $launch" begin
            NC.compare(parsed, expected)
        end
        counts = Test.get_test_counts(result)
        push!(validation, (launch=launch, passes=counts.passes + counts.cumulative_passes,
            fails=counts.fails + counts.cumulative_fails, errors=counts.errors + counts.cumulative_errors))
    end
    return (
        settings=(; days, rate, reproductive, retain, repeats, launches), bundle=bundle,
        scope="Native simulate_full_xpalm: runtime model replacement + instantiate + Constants/forcing construction + daily steps; excludes startup, explicit GC, serialization, parsing and parity checks; build-time authoring/program reused",
        median_s=median(row.time_s for row in trials), min_s=minimum(row.time_s for row in trials),
        warmups=warmups, trials=trials, validation=validation,
        validated=(objects=expected.objects, applications=expected.applications,
            canonical_fields=length(expected.states), retained_samples=length(expected.samples),
            rng_streams=length(expected.rng), canonical_state=true, topology=true,
            retained_sample_parity=retain, owned_rng=true),
        build=build, binary_sha256=bytes2hex(sha256(read(joinpath(bundle, "bin", "pse_program")))),
        app_sha256=build.app_sha256,
    )
end

end # module FullXPalmNativePerformance
