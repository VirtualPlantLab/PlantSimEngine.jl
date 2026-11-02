isdefined(@__MODULE__, :DownstreamMAESPAEncoding) || include(joinpath(@__DIR__, "downstream_maespa_encoding.jl"))

module DownstreamMAESPAEncodingChecks

using Test, Dates
import PlantSimEngine, MAESPA
import ..DownstreamMAESPAEncoding

const ENCODER_SOURCE = joinpath(@__DIR__, "downstream_maespa_encoding.jl")
_tag(encoder, type) = Base.invokelatest(encoder._type_tag, type)

function _encode(encoder, fields; from=nothing)
    buffer = IOBuffer()
    Base.invokelatest(encoder.encode_record, IOContext(buffer, :module=>from, :compact=>true), fields)
    return String(take!(buffer))
end

function _contexts()
    bare = Module(gensym(:MAESPAEncodingBare))
    imported = Module(gensym(:MAESPAEncodingImported))
    Core.eval(imported, :(using PlantSimEngine, MAESPA, Dates))
    # Include the identical encoder in both scopes. Tests create no methods in
    # the scientific packages, existing runtimes, or Main's import namespace.
    Base.include(bare, ENCODER_SOURCE)
    Base.include(imported, ENCODER_SOURCE)
    return bare, imported
end

"""
    check_encoding(; encoder=DownstreamMAESPAEncoding)

Host-only checks for deterministic, fully qualified authoring-time type tags.
Run this helper through Kaimon after loading the current encoder. Pass an
existing observation encoder explicitly when checking its refreshed methods.
The helper does not execute a scientific model or compile a native bundle.

It checks identical tags across module/import/IO contexts, distinct identities
for equal short type names and different parameters, and unchanged String and
Symbol payload bytes (including strings that resemble type tags). Native raw
record parity remains a separate gate using freshly encoded original records.
"""
function check_encoding(; encoder=DownstreamMAESPAEncoding)
    bare, imported = _contexts()
    encoders = (encoder, getglobal(bare, :DownstreamMAESPAEncoding),
        getglobal(imported, :DownstreamMAESPAEncoding))
    types = (Float32, Float64, Int64, Bool, String, Symbol, Nothing, Missing,
        PlantSimEngine.ObjectId{Symbol}, Vector{PlantSimEngine.ObjectId{Symbol}},
        Tuple{PlantSimEngine.ObjectId{Symbol}, DateTime},
        NamedTuple{(:object,), Tuple{PlantSimEngine.ObjectId{Symbol}}},
        MAESPA.MAESPACanopyAtmosphere{Float64, Float64})
    # These unexported test types intentionally share a short name. Their
    # defining module is part of the encoded identity, even when imported.
    left = Module(gensym(:MAESPAEncodingIdentityLeft))
    right = Module(gensym(:MAESPAEncodingIdentityRight))
    Core.eval(left, :(struct SameName{T}; value::T; end))
    Core.eval(right, :(struct SameName{T}; value::T; end))
    left_type = Core.apply_type(getglobal(left, :SameName), Float64)
    right_type = Core.apply_type(getglobal(right, :SameName), Float64)
    payload = "PlantSimEngine.ObjectId{Symbol}: MAESPA.Canopy | ; { } [ ] = \" λ\n"
    symbol_payload = Symbol("PlantSimEngine.ObjectId.MAESPA")
    record = ("O", PlantSimEngine.ObjectId(:probe), 1.0,
        symbol_payload, payload, [Float32(1), Float32(-0.0)])
    @testset "MAESPA observation codec context and identity" begin
        for type in types
            expected = sprint(show, type; context=(:module=>nothing, :compact=>false))
            for candidate in encoders
                @test _tag(candidate, type) == expected
            end
        end
        @test occursin("PlantSimEngine.ObjectId", _tag(encoder, PlantSimEngine.ObjectId{Symbol}))
        @test occursin("MAESPA.MAESPACanopyAtmosphere",
            _tag(encoder, MAESPA.MAESPACanopyAtmosphere{Float64, Float64}))
        @test _tag(encoder, Float32) != _tag(encoder, Float64)
        @test _tag(encoder, PlantSimEngine.ObjectId{Int}) !=
            _tag(encoder, PlantSimEngine.ObjectId{Symbol})
        @test _tag(encoder, left_type) != _tag(encoder, right_type)
        for type in (left_type, right_type), candidate in encoders
            @test _tag(candidate, type) ==
                sprint(show, type; context=(:module=>nothing, :compact=>false))
        end
        expected = _encode(encoder, record)
        for candidate in encoders, context in (nothing, bare, imported, Main)
            @test _encode(candidate, record; from=context) == expected
        end
        @test _encode(encoder, (payload,)) ==
            _tag(encoder, String) * ":" * string(ncodeunits(payload)) * ":" * payload * "|\n"
        @test _encode(encoder, (symbol_payload,)) ==
            _tag(encoder, Symbol) * ":" * String(symbol_payload) * "|\n"
        for kind in ("F", "T", "S", "H", "O", "E"), candidate in encoders
            @test Base.invokelatest(candidate.record_prefix, kind) * "\n" == _encode(candidate, (kind,))
        end
    end
    return (type_schemas=length(types)+2, encoder_contexts=length(encoders),
        io_contexts=4, fully_qualified_type_tags=true,
        distinct_type_identity_preserved=true, string_and_symbol_payloads_unchanged=true,
        scientific_execution=false)
end

end # module DownstreamMAESPAEncodingChecks
