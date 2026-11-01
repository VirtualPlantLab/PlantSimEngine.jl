# Include and execute through Kaimon. Only the already-built native executable
# is launched below; this driver never starts another Julia process.
isdefined(Main, :FullXPalmChecks) || include(joinpath(@__DIR__, "full_xpalm_checks.jl"))

module FullXPalmNativeChecks

using Test
using TOML
using PlantSimEngine
import ..FullXPalmFixture as XF
import ..FullXPalmChecks as FullChecks
const PSE = PlantSimEngine

const CASES = (
    (days=3, rate=0.05, reproductive=false),
    (days=12, rate=0.3, reproductive=true),
    (days=5, rate=0.075, reproductive=false),
    (days=9, rate=0.25, reproductive=true),
)
const StateKey = Tuple{Symbol,Int,Symbol}
const SampleKey = Tuple{Symbol,Int,Int,Symbol}
const RNGKey = Tuple{Symbol,Symbol}
const Topology = Tuple{Symbol,Int,Symbol,Int} # category, parent (zero at root), link, index

# Decode against the original result's actual type, never by evaluating text.
_decode(token, example::ObjectId) = ObjectId(parse(typeof(example.value), token))
_decode(token, example::Bool) = parse(Bool, token)
_decode(token, example::Integer) = parse(typeof(example), token)
_decode(token, example::AbstractFloat) = parse(typeof(example), token)
_decode(token, example::Symbol) = Symbol(token)
_decode(token, example::AbstractString) = String(token)
function _decode(token, ::Nothing)
    token == "nothing" || error("expected nothing, got $token")
    return nothing
end
function _array_tokens(token)
    startswith(token, '[') && endswith(token, ']') || error("invalid array encoding: $token")
    body = chop(token; head=1, tail=1)
    isempty(body) && return String[]
    result = String[]
    depth = 0
    beginning = firstindex(body)
    for index in eachindex(body)
        char = body[index]
        char == '[' && (depth += 1)
        char == ']' && (depth -= 1)
        depth >= 0 || error("unbalanced array encoding")
        if char == ';' && depth == 0
            push!(result, String(SubString(body, beginning, prevind(body, index))))
            beginning = nextind(body, index)
        end
    end
    depth == 0 || error("unbalanced array encoding")
    push!(result, String(SubString(body, beginning, lastindex(body))))
    return result
end
function _decode(token, example::AbstractArray)
    ndims(example) == 1 || error("native protocol does not encode array dimensions")
    tokens = _array_tokens(token)
    length(tokens) == length(example) || error("native array length differs from original")
    return [_decode(value, original) for (value, original) in zip(tokens, example)]
end
_decode(token, example) = error("unsupported original payload type $(typeof(example))")

function reference(args)
    setup = XF.authoring(; rate=args.rate, reproductive=args.reproductive)
    simulation = XF.ordinary(XF.rows(args.days); rate=args.rate, reproductive=args.reproductive)
    objects = XF.fingerprint(PSE.runtime_model(simulation), setup.variables)
    topology = Dict{Int,Topology}()
    states = Dict{StateKey,Any}()
    for row in objects
        id = row.object_id.value
        topology[id] = (row.scale, isnothing(row.parent_id) ? 0 : row.parent_id.value,
            row.link, row.index)
        for (variable, value) in pairs(row.status)
            states[(row.scale, id, variable)] = value
        end
    end
    samples = Dict{SampleKey,Any}()
    for row in PSE.collect_outputs(simulation; sink=nothing)
        key = (row.application_id, ObjectId(row.object_id).value, row.timestep, row.variable)
        haskey(samples, key) && error("duplicate original output key $key")
        samples[key] = FullChecks._plain(row.value)
    end
    rng = Dict{RNGKey,NTuple{4,UInt64}}()
    for application in PSE.runtime_model(simulation).applications
        model = application.model
        for field in (:rng, :random_generator)
            hasfield(typeof(model), field) || continue
            probe = copy(getfield(model, field))
            # Match the executable's four SCALAR draws, not an array fill path.
            rng[(application.name, field)] = ntuple(_ -> XF.XPalm.Random.rand(probe, UInt64), 4)
        end
    end
    return (objects=length(objects), step=args.days, applications=length(setup.applications),
        topology, states, samples, rng)
end

function _put_unique!(dictionary, key, value)
    haskey(dictionary, key) && error("duplicate native record $key")
    dictionary[key] = value
    return nothing
end
function parse_native(output)
    header = nothing
    topology = Dict{Int,Topology}()
    state_topology = Dict{Int,Topology}()
    states = Dict{StateKey,String}()
    samples = Dict{SampleKey,String}()
    rng = Dict{RNGKey,NTuple{4,UInt64}}()
    for line in split(chomp(output), '\n')
        fields = split(line, ',')
        tag = first(fields)
        isnothing(header) && tag != "F" && error("full header must be first")
        if tag == "F"
            length(fields) == 4 && isnothing(header) || error("invalid/duplicate full header")
            header = (objects=parse(Int,fields[2]), step=parse(Int,fields[3]), applications=parse(Int,fields[4]))
        elseif tag == "T"
            length(fields) == 6 || error("invalid topology record")
            id = parse(Int, fields[3])
            _put_unique!(topology, id, (Symbol(fields[2]), parse(Int,fields[4]), Symbol(fields[5]), parse(Int,fields[6])))
        elseif tag == "S"
            length(fields) == 8 || error("invalid canonical state record")
            category = Symbol(fields[2]); id = parse(Int,fields[3])
            metadata = (category, parse(Int,fields[4]), Symbol(fields[5]), parse(Int,fields[6]))
            haskey(state_topology,id) && state_topology[id] != metadata && error("inconsistent state topology for $id")
            state_topology[id] = metadata
            _put_unique!(states, (category,id,Symbol(fields[7])), String(fields[8]))
        elseif tag == "O"
            length(fields) == 6 || error("invalid retained output record")
            _put_unique!(samples, (Symbol(fields[2]),parse(Int,fields[3]),parse(Int,fields[4]),Symbol(fields[5])), String(fields[6]))
        elseif tag == "R"
            length(fields) == 4 || error("invalid RNG record")
            tokens = _array_tokens(fields[4])
            length(tokens) == 4 || error("expected four future RNG draws")
            _put_unique!(rng, (Symbol(fields[2]),Symbol(fields[3])), Tuple(parse.(UInt64,tokens)))
        else
            error("unexpected native record tag $(repr(tag))")
        end
    end
    isnothing(header) && error("missing full native header")
    length(topology) == header.objects || error("native topology does not cover every header object")
    for (id, metadata) in state_topology
        get(topology,id,nothing) == metadata || error("state/topology record mismatch for $id")
    end
    return (; header..., topology, states, samples, rng)
end

function native(exe, args; home=nothing, depot=nothing, cwd=nothing)
    command = Cmd([abspath(exe), "full", string(args.days), string(args.rate), string(args.reproductive)])
    isnothing(cwd) || (command = Cmd(command; dir=cwd))
    command = addenv(command, "JULIA_PROJECT"=>nothing, "JULIA_LOAD_PATH"=>nothing)
    isnothing(home) || (command = addenv(command, "HOME"=>home))
    isnothing(depot) || (command = addenv(command, "JULIA_DEPOT_PATH"=>depot))
    out = IOBuffer(); err = IOBuffer()
    process = run(pipeline(ignorestatus(command); stdout=out, stderr=err))
    success(process) || error("full native exit $(process.exitcode): " * String(take!(err)))
    return parse_native(String(take!(out)))
end

function compare(actual, expected)
    @test (actual.objects,actual.step,actual.applications) == (expected.objects,expected.step,expected.applications)
    @test expected.applications == 61
    @test actual.topology == expected.topology
    @test Set(keys(actual.states)) == Set(keys(expected.states))
    for key in intersect(Set(keys(actual.states)), Set(keys(expected.states)))
        @testset "canonical $key" begin
            @test FullChecks._equal(_decode(actual.states[key],expected.states[key]), expected.states[key])
        end
    end
    @test Set(keys(actual.samples)) == Set(keys(expected.samples))
    for key in intersect(Set(keys(actual.samples)), Set(keys(expected.samples)))
        @testset "retained $key" begin
            @test FullChecks._equal(_decode(actual.samples[key],expected.samples[key]), expected.samples[key])
        end
    end
    @test Set(keys(actual.rng)) == Set(keys(expected.rng))
    @test actual.rng == expected.rng
    return nothing
end

function _case_evidence(args, observed, elapsed)
    return (inputs=args, applications=observed.applications, objects=observed.objects,
        days=observed.step, canonical_variables=length(observed.states), samples=length(observed.samples),
        rng_streams=length(observed.rng), male_objects=count(row->row[1]===:Male,values(observed.topology)),
        female_objects=count(row->row[1]===:Female,values(observed.topology)), process_wall_s=elapsed)
end

"""Compare every canonical field, retained sample and future RNG draw to original PSE.
`relocated_bundle` can reuse a bundle copied by another native check. Otherwise,
relocation copies the bundle exactly once, removes it afterward, and runs with
fresh HOME, empty external depot and empty cwd. The launcher supplies only its
bundled artifacts. This is a same-host relocation check.
The original PSE reference has been executed for the qualifying 12-day, rate
0.3 reproductive case with seeds 1: 54 objects, including 7 Male and 3 Female.
`require_both_sexes=true` requires positive counts for that qualifying case;
alternate cases still compare exactly to their own original PSE reference.
"""
function run_checks(bundle=readchomp(joinpath(@__DIR__,"build","latest.txt"));
                    cases=CASES, relocate=true, relocated_bundle=nothing,
                    require_both_sexes=true)
    isempty(cases) && throw(ArgumentError("provide at least one native comparison case"))
    bundle = abspath(bundle)
    exe = joinpath(bundle,"bin","run-pse-program")
    isfile(exe) || error("missing native launcher $exe")
    build = TOML.parsefile(joinpath(bundle,"build.toml"))
    build["trim"] == "safe" || error("full checks require a safe-trim JuliaC build")
    evidence = NamedTuple[]
    references = Any[]
    relocation = nothing
    result = @testset "Safe native full original XPalm" begin
        for args in cases
            @testset "$(args.days) days, rate $(args.rate), reproduction $(args.reproductive)" begin
                expected = reference(args)
                push!(references,expected)
                measurement = @timed native(exe,args)
                observed = measurement.value
                compare(observed,expected)
                row = _case_evidence(args,observed,measurement.time)
                push!(evidence,row)
                if require_both_sexes && args.days == 12 && args.rate == 0.3 && args.reproductive
                    @test row.male_objects > 0
                    @test row.female_objects > 0
                end
            end
        end
        if relocate
            scratch = mktempdir()
            try
                moved = isnothing(relocated_bundle) ? joinpath(scratch,"bundle") : abspath(relocated_bundle)
                isnothing(relocated_bundle) && cp(bundle,moved)
                home = mkpath(joinpath(scratch,"home"))
                depot = mkpath(joinpath(scratch,"depot"))
                cwd = mkpath(joinpath(scratch,"cwd"))
                case_index = something(findfirst(args->args.reproductive,cases),firstindex(cases))
                args = cases[case_index]
                expected = references[case_index]
                measurement = @timed native(joinpath(moved,"bin","run-pse-program"),args;home,depot,cwd)
                compare(measurement.value,expected)
                relocation = (inputs=args, applications=measurement.value.applications,
                    objects=measurement.value.objects, samples=length(measurement.value.samples),
                    fresh_home=true, empty_external_depot=true, empty_cwd=true,
                    process_wall_s=measurement.time)
            finally
                rm(scratch;recursive=true,force=true)
            end
        end
    end
    counts = Test.get_test_counts(result)
    return (passes=counts.passes+counts.cumulative_passes,
        fails=counts.fails+counts.cumulative_fails, errors=counts.errors+counts.cumulative_errors,
        cases=evidence, relocation, build=(julia=build["julia"],juliac=build["juliac"],trim=build["trim"]),
        both_sexes_required=require_both_sexes, platform=Sys.MACHINE)
end

end # module FullXPalmNativeChecks
