# Included inside XPalmScaling. Native parsing/decoding reuse the established
# full protocol, but comparisons avoid a TestSet object for every scalar/sample.
function _validate_native(checks, actual, expected, applications)
    (actual.objects, actual.step, actual.applications) ==
        (length(expected.objects), expected.steps, applications) || error("native header/work mismatch")
    topology = Dict(object.object_id.value => (object.scale,
        isnothing(object.parent_id) ? 0 : object.parent_id.value, object.link, object.index)
        for object in expected.objects)
    actual.topology == topology || error("native topology protocol mismatch")
    states = Dict((object.scale, object.object_id.value, variable) => value
        for object in expected.objects for (variable, value) in pairs(object.status))
    Set(keys(actual.states)) == Set(keys(states)) || error("native canonical field coverage mismatch")
    for (key, example) in states
        checks.FullChecks._equal(checks._decode(actual.states[key], example), example) ||
            error("native canonical mismatch at $key")
    end
    Set(keys(actual.samples)) == Set(keys(expected.samples)) || error("native retained sample coverage mismatch")
    for (key, example) in expected.samples
        checks.FullChecks._equal(checks._decode(actual.samples[key], example), example) ||
            error("native retained value mismatch at $key")
    end
    actual.rng == expected.native_rng || error("native scalar RNG probes differ")
    return (canonical_fields=length(states), retained_samples=length(expected.samples),
        rng_streams=length(expected.native_rng), objects=actual.objects,
        topology_schema="category/parent/link/index; existing native full protocol")
end

"""
    _native_scaling(bundle, checks, performance, context, expected;
                    command_factory=nothing, repeats=3, launches=3)

Internal serial native phase. `checks` is a loaded FullXPalmNativeChecks module.
An optional factory `(executable, settings, repeats) -> Cmd` may select a copied
app's exact-default entry, which must emit unchanged P/F/T/S/O/R records with
P0 followed by repetitions and serialize only its final result after timing.
The factory is explicit because standard perffull accepts one common rate and
cannot represent the package's unequal phyllochron endpoints.
"""
function _native_scaling(bundle, checks, performance, context, expected;
                         command_factory=nothing, repeats=3, launches=3)
    isnothing(bundle) && return (supported=false, reason="native bundle not supplied")
    if context.settings.profile === :package_defaults && isnothing(command_factory)
        return (supported=false, reason="standard perffull cannot represent untouched package parameters; provide a separately built exact-profile entry and command factory")
    end
    isnothing(checks) && error("native_checks must be a loaded FullXPalmNativeChecks module")
    launches isa Integer && launches > 0 || throw(ArgumentError("native_launches must be positive"))
    bundle = abspath(bundle)
    build = TOML.parsefile(joinpath(bundle, "build.toml"))
    get(build, "trim", nothing) == "safe" || error("native scaling requires safe trimming")
    get(build, "cpu", nothing) == "generic" || error("native scaling requires generic CPU")
    executable = joinpath(bundle, "bin", "run-pse-program")
    binary = joinpath(bundle, "bin", "pse_program")
    binary_hash = bytes2hex(sha256(read(binary)))
    settings = context.settings
    trials = NamedTuple[]
    warmups = NamedTuple[]
    validation = NamedTuple[]
    for launch in 1:launches
        command = isnothing(command_factory) ? Cmd([executable, "perffull", string(settings.days),
            string(settings.rate), string(settings.reproductive), string(repeats), string(settings.retain)]) :
            command_factory(executable, settings, repeats)
        command isa Cmd || error("native_command must return Cmd")
        command = addenv(command, "JULIA_PROJECT" => nothing, "JULIA_LOAD_PATH" => nothing)
        GC.gc()
        output = read(command, String)
        lines = split(chomp(output), '\n')
        timings = filter(line -> startswith(line, "P,"), lines)
        length(timings) == repeats + 1 || error("native sample count mismatch")
        for (index, line) in enumerate(timings)
            fields = split(line, ',')
            length(fields) == 5 || error("invalid native timing row")
            parse(Int, fields[2]) == index - 1 || error("native trial sequence mismatch")
            parse(Int, fields[4]) == length(expected.objects) || error("native timing object count mismatch")
            parse(Int, fields[5]) == context.days || error("native timing step mismatch")
            row = (launch=launch, trial=index - 1, time_s=parse(Int, fields[3]) * 1e-9)
            push!(index == 1 ? warmups : trials, row)
        end
        actual = checks.parse_native(join(filter(line -> !startswith(line, "P,"), lines), '\n'))
        counts = _validate_native(checks, actual, expected, length(context.setup.applications))
        push!(validation, merge((launch=launch,), counts))
    end
    bytes2hex(sha256(read(binary))) == binary_hash || error("native binary changed during measurement")
    return (supported=true, arm=:current_juliac_safe, median_s=median(row.time_s for row in trials),
        min_s=minimum(row.time_s for row in trials), trials=trials, warmups=warmups, validation=validation,
        metadata=(bundle=bundle, binary_sha256=binary_hash, app_sha256=get(build, "app_sha256", missing),
            julia=get(build, "julia", missing), juliac=get(build, "juliac", missing), trim="safe", cpu="generic"),
        scope="Internal simulate_full_xpalm fresh setup/forcing/Constants/daily steps; program/scientific authoring, startup, P0, explicit GC, printing and host parity excluded; native allocation bytes not measured")
end
