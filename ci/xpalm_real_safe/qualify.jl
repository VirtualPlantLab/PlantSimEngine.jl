# Isolated scientific qualification; no elapsed-time or benchmark verdict.
using Pkg, TOML, SHA, Dates, Test
const ROOT = realpath(ENV["GITHUB_WORKSPACE"])
const RECIPE = joinpath(ROOT, "ci", "xpalm_real_safe")
const APP = joinpath(RECIPE, "app")
const BUILD = joinpath(RECIPE, "build")
const OUT = abspath(ENV["XPALM_EVIDENCE"])
const PINS = TOML.parsefile(joinpath(RECIPE, "provenance.toml"))
const SCIENTIFIC = Dict("PlantSimEngine" => ROOT,
    "XPalm" => joinpath(ROOT, "scientific", "XPalm"),
    "PlantGeom" => joinpath(ROOT, "scientific", "PlantGeom"))
mkpath(OUT)
function save(path, value)
    open(path, "w") do io
        TOML.print(io, value)
    end
end
function phase(name)
    save(joinpath(OUT, "phase.toml"), Dict("phase" => name, "utc" => string(now(UTC))))
    println("XPALM_QUALIFICATION\t", name)
    flush(stdout)
end
function runtime_sources(path)
    result = Dict{String,String}()
    for component in ("src", "ext")
        directory = joinpath(path, component)
        isdir(directory) || continue
        for (directory, _, files) in walkdir(directory), name in files
            endswith(name, ".jl") || continue
            file = joinpath(directory, name)
            result[relpath(file, path)] = bytes2hex(sha256(read(file)))
        end
    end
    result["Project.toml"] = bytes2hex(sha256(read(joinpath(path, "Project.toml"))))
    return result
end
function check_sources()
    for (name, expected) in (("XPalm", PINS["xpalm"]), ("PlantGeom", PINS["plantgeom"]))
        path = SCIENTIFIC[name]
        strip(read(`git -C $path rev-parse HEAD`, String)) == expected || error("Wrong public scientific revision.")
        isempty(read(`git -C $path status --porcelain --untracked-files=no`, String)) || error("Scientific checkout was edited.")
    end
    head = strip(read(`git -C $ROOT rev-parse HEAD`, String))
    head == ENV["GITHUB_SHA"] || error("Wrong qualification commit.")
    run(`git -C $ROOT merge-base --is-ancestor $(PINS["base_pse"]) HEAD`)
    changed = Set(split(strip(read(`git -C $ROOT diff --name-only $(PINS["base_pse"]) HEAD -- src ext Project.toml`, String)), '\n'))
    changed == Set(["src/composite_model/runtime_outputs.jl", "src/composite_model/execution_dispatch.jl"]) || error("Unexpected experimental engine delta.")
    for (file, expected) in PINS["pse_experimental_files"]
        bytes2hex(sha256(read(joinpath(ROOT, file)))) == expected || error("Experimental source drift.")
    end
    for (file, expected) in PINS["app_files"]
        bytes2hex(sha256(read(joinpath(APP, file)))) == expected || error("Application source drift.")
    end
    for (file, expected) in PINS["reference_files"]
        bytes2hex(sha256(read(joinpath(SCIENTIFIC["XPalm"], file)))) == expected || error("Historical reference file drift.")
    end
    meteo = joinpath(SCIENTIFIC["XPalm"], "0-data", "meteo.csv")
    bytes2hex(sha256(read(meteo))) == "3406fa2cc253c40d84610aacebe7e537fe9d2205882e1dc040c58cf169c7c653" || error("Official forcing drift.")
    return nothing
end
function manifest_rows(path)
    data = TOML.parsefile(path)
    return Dict(name => deepcopy(only(entries)) for (name, entries) in data["deps"])
end
function graph(path; roots=nothing)
    available = manifest_rows(path)
    pending = isnothing(roots) ? collect(keys(available)) : collect(roots)
    selected = Dict{String,Any}()
    while !isempty(pending)
        name = pop!(pending)
        haskey(selected, name) && continue
        haskey(available, name) || error("Missing scientific dependency: $name")
        row = available[name]
        # Registry display labels are not a package UUID/version/tree identity.
        pop!(row, "registries", nothing)
        for field in ("deps", "weakdeps")
            declared = get(row, field, nothing)
            if declared isa AbstractVector
                row[field] = Dict(dependency => available[dependency]["uuid"] for dependency in declared)
            end
        end
        dependencies = get(row, "deps", String[])
        append!(pending, dependencies isa AbstractDict ? collect(keys(dependencies)) : dependencies)
        if haskey(row, "path")
            row["path"] = normpath(joinpath(dirname(path), row["path"]))
        end
        if haskey(SCIENTIFIC, name)
            haskey(row, "path") || error("Scientific dependency must use its checked checkout.")
            runtime_sources(row["path"]) == runtime_sources(SCIENTIFIC[name]) || error("Scientific runtime source drift.")
            row["path"] = name  # Stable public source identity, independent of runner location.
        end
        selected[name] = row
    end
    return selected
end
function materialize_paths(project)
    file = joinpath(project, "Project.toml")
    data = TOML.parsefile(file)
    for (name, source) in get(data, "sources", Dict())
        haskey(source, "path") || continue
        source["path"] = normpath(joinpath(project, source["path"]))
    end
    save(file, data)
    file = joinpath(project, "Manifest.toml")
    data = TOML.parsefile(file)
    for entries in values(data["deps"]), row in entries
        haskey(row, "path") || continue
        row["path"] = normpath(joinpath(project, row["path"]))
    end
    save(file, data)
end
function prepare()
    VERSION == VersionNumber(PINS["julia"]) || error("Wrong Julia version.")
    check_sources()
    phase("before-environment-resolution")
    Pkg.Registry.add("General")
    materialize_paths(APP)
    seed = graph(joinpath(APP, "Manifest.toml"))
    length(seed) == 144 || error("Wrong historical scientific seed.")
    save(joinpath(OUT, "seed-scientific-graph.toml"), seed)
    Pkg.activate(APP)
    Pkg.resolve()
    Pkg.instantiate(; allow_autoprecomp=false)
    graph(joinpath(APP, "Manifest.toml")) == seed || error("Scientific seed identities changed during resolution.")
    mkpath(BUILD)
    project = TOML.parsefile(joinpath(APP, "Project.toml"))
    project = Dict("deps" => deepcopy(project["deps"]),
        "sources" => deepcopy(project["sources"]), "compat" => Dict("JuliaC" => "=0.3.12"))
    project["deps"]["JuliaC"] = "acedd4c2-ced6-4a15-accc-2607eb759ba2"
    save(joinpath(BUILD, "Project.toml"), project)
    cp(joinpath(APP, "Manifest.toml"), joinpath(BUILD, "Manifest.toml"))
    Pkg.activate(BUILD)
    Pkg.add(PackageSpec(; name="JuliaC", version=v"0.3.12"); preserve=Pkg.PRESERVE_ALL)
    Pkg.instantiate(; allow_autoprecomp=false)
    roots = collect(keys(TOML.parsefile(joinpath(APP, "Project.toml"))["deps"]))
    graph(joinpath(APP, "Manifest.toml"); roots) == graph(joinpath(BUILD, "Manifest.toml"); roots) || error("Build scientific dependency graph changed.")
    for (label, project) in (("app", APP), ("build", BUILD)), filename in ("Project.toml", "Manifest.toml")
        cp(joinpath(project, filename), joinpath(OUT, label * "-" * filename))
    end
    save(joinpath(OUT, "source-pins.toml"), Dict("qualification_commit" => ENV["GITHUB_SHA"],
        "public_pse_base" => PINS["base_pse"], "XPalm" => PINS["xpalm"], "PlantGeom" => PINS["plantgeom"],
        "Julia" => string(VERSION), "JuliaC" => PINS["juliac"], "scientific_seed_preserved" => true))
    phase("environment-resolution-returned")
end
function host()
    check_sources()
    phase("before-independent-official-full-reference")
    reference = OfficialXPalmOracle.run_reference_regression_scenario()
    @test nrow(reference.tables.daily) == 4160
    checkpoints = CSV.read(joinpath(OfficialXPalmOracle.BASELINE, "trajectory_checkpoints.csv"), DataFrame; types=Dict(:date=>Date))
    indices = OfficialXPalmOracle.reference_regression_checkpoint_indices(reference.tables.daily.date)
    OfficialXPalmOracle.compare_daily(reference.tables.daily[indices, :], checkpoints)
    CSV.write(joinpath(OUT, "ordinary-4160.csv"), reference.tables.daily)
    save(joinpath(OUT, "host-completed.toml"), Dict("completed" => true, "days" => 4160,
        "two_real_witness_trajectories" => true, "T0_T1_public_controls" => true,
        "independent_ordinary_reference" => true, "official_checkpoints" => true))
    check_sources()
    phase("host-complete")
end
function verify_compiler()
    monitor = joinpath(RECIPE, "compiler_monitor.py")
    receipt = joinpath(OUT, "compiler-monitor.json")
    verification = joinpath(OUT, "compiler-verification-input.toml")
    run(`python3 $monitor --verify-receipt $receipt --verification $verification`)
    rows = get(TOML.parsefile(verification), "observations", Any[])
    roots = collect(keys(TOML.parsefile(joinpath(APP, "Project.toml"))["deps"]))
    expected = graph(joinpath(APP, "Manifest.toml"); roots)
    compilers = 0
    for row in rows
        get(row, "is_safe_compiler", false) || continue
        row["safe"] && row["generic"] && row["no_L"] || error("Actual CLI is not stock safe/generic/no-L.")
        graph(row["manifest"]; roots) == expected || error("Actual compiler scientific graph drift.")
        compilers += 1
    end
    compilers > 0 || error("No actual safe compiler CLI/Project/Manifest captured.")
    save(joinpath(OUT, "compiler-science-verified.toml"), Dict("verified" => true, "actual_compilers" => compilers))
end
function build_and_check()
    check_sources()
    TOML.parsefile(joinpath(OUT, "host-completed.toml"))["completed"] || error("Real host gate absent.")
    Base.pkgversion(JuliaC) == v"0.3.12" || error("Wrong JuliaC version.")
    runtime_sources(pkgdir(PSE)) == runtime_sources(ROOT) || error("Wrong loaded engine.")
    phase("before-public-stock-safe-build")
    logfile = joinpath(OUT, "compile.log")
    finished = joinpath(OUT, "compile-finished")
    monitor = joinpath(RECIPE, "compiler_monitor.py")
    process = open(joinpath(OUT, "monitor.log"), "w") do io
        run(pipeline(`python3 $monitor --parent $(getpid()) --log $logfile --finished $finished --receipt $(joinpath(OUT,"compiler-monitor.json")) --errors 3 --seconds 21600`;
            stdout=io, stderr=io); wait=false)
    end
    artifact = try
        open(logfile, "w") do io
            redirect_stdio(stdout=io, stderr=io) do
                PSE.Compilation.compile(APP; destination=ENV["XPALM_BUNDLE"], name="xpalm")
            end
        end
    finally
        write(finished, "The public compiler returned or threw.\n")
        wait(process)
    end
    phase("public-stock-safe-build-returned")
    @test isfile(artifact.executable)
    verify_compiler()
    binary_hash = bytes2hex(sha256(read(artifact.executable)))
    save(joinpath(OUT, "build-result.toml"), Dict("executable" => artifact.executable, "sha256" => binary_hash))
    for days in (0, 1, 4160)
        phase("running-same-native-binary-$days")
        open(joinpath(OUT, "native-$days.csv"), "w") do io
            run(pipeline(`$(artifact.executable) $days`; stdout=io))
        end
        @test bytes2hex(sha256(read(artifact.executable))) == binary_hash
    end
    phase("checking-native-0-1-4160-parity")
    native(days) = CSV.read(joinpath(OUT, "native-$days.csv"), DataFrame; types=Dict(:date=>Date))
    reference = OfficialXPalmOracle.official_t1()
    @test names(native(0)) == names(reference)
    @test nrow(native(0)) == 0
    OfficialXPalmOracle.compare_daily(native(1), reference)
    actual = native(4160)
    @test nrow(actual) == 4160
    ordinary = CSV.read(joinpath(OUT, "ordinary-4160.csv"), DataFrame; types=Dict(:date=>Date))
    OfficialXPalmOracle.compare_daily(actual, ordinary)
    checkpoints = CSV.read(joinpath(OfficialXPalmOracle.BASELINE, "trajectory_checkpoints.csv"), DataFrame; types=Dict(:date=>Date))
    indices = OfficialXPalmOracle.reference_regression_checkpoint_indices(actual.date)
    OfficialXPalmOracle.compare_daily(actual[indices, :], checkpoints)
    check_sources()
    save(joinpath(OUT, "completed.toml"), Dict("completed" => true, "native_0_1_4160_parity" => true,
        "stock_safe_generic_no_L" => true, "days" => 4160, "columns" => 19,
        "binary_sha256" => binary_hash, "qualification_commit" => ENV["GITHUB_SHA"], "benchmark" => false))
    phase("complete")
end
length(ARGS) == 1 || error("Pass prepare, host, or native.")
if ARGS[1] == "prepare"
    prepare()
elseif ARGS[1] == "host"
    check_sources()
    phase("before-real-two-trajectory-preparation-and-T0-T1-tests")
    # Include at top level so the unchanged test/oracle methods are visible.
    include(joinpath(APP, "test", "runtests.jl"))
    phase("real-two-trajectory-preparation-and-T0-T1-tests-returned")
    host()
elseif ARGS[1] == "native"
    using CSV, DataFrames
    import PlantSimEngine as PSE
    import JuliaC
    include(joinpath(APP, "test", "oracle.jl"))
    build_and_check()
else
    error("Unknown qualification mode.")
end
