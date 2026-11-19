using PlantSimEngine, SHA, TOML

const root = pkgdir(PlantSimEngine)
@assert realpath(root) == realpath(ARGS[1])
include(joinpath(root, "test", "integration", "native_fixture_apps.jl"))
const fixture = NativeFixtureApps.stage_native_fixture(
    joinpath(root, "test", "fixtures", "local_palm_leaf_birth"))
const entry = joinpath(fixture, "src", "PSELocalPalmLeafBirth.jl")

# Both processes start with the package loaded. Including this same app in
# each process trains the input types, replays births and prepares a fresh palm.
const before = Base.jit_total_bytes()
const prepared = @timed include(entry)
const prep_bytes = Base.jit_total_bytes() - before
const app = PSELocalPalmLeafBirth
const compiled = app.STATE.simulation.compiled
const binding = eltype(compiled.input_bindings)
const shared = valtype(typeof(compiled.many_input_binding_cache.by_query))
const many = filter(Base.uniontypes(binding)) do B
    fieldtype(fieldtype(B, :plan), :selector) <: PlantSimEngine.Many
end
@assert 0 < length(many) < length(Base.uniontypes(binding))
@assert shared === (ARGS[1] == "reference" ? binding : Union{many...})
const first_execution = @timed app.native_run!(app.STATE, 100)
const result = first_execution.value
@assert result.ok
const palm = app.a_report(result.state, 100)
const neighbours = app.neighbour_report(result.state, result.timings)
@assert neighbours[end-5] == 0x50484153454e5343
digest(words) = bytes2hex(sha256(reinterpret(UInt8, words)))
open(ARGS[2], "w") do io
    TOML.print(io, Dict(
        "input_types" => length(Base.uniontypes(binding)),
        "many_types" => length(many),
        "cache_types" => length(Base.uniontypes(shared)),
        "fixture_prepare_jit_bytes" => prep_bytes,
        "fixture_prepare_seconds" => prepared.time,
        "first_execution_seconds" => first_execution.time,
        "palm_report" => digest(palm),
        "neighbours_report" => digest(neighbours[1:end-6]),
    ))
end
