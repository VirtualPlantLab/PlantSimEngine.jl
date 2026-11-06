module InputDefaultValuesChecks

using PlantSimEngine
using Test
const PSE = PlantSimEngine

@testset "concrete declaration tuples infer ordered defaults and retain live aliases" begin
    buffer = Float32[2, 3]
    cell = Ref{Any}(Float32[4, 5])
    cells = Base.RefValue{Any}[cell, Ref{Any}(6f0)]
    schema = (required=Required(Real), scalar=Default(1.25f0),
        buffer=Default(buffer), cell=Default(cell), cells=Default(cells),
        final_required=Required(AbstractVector))
    defaults = @inferred PSE._input_default_values(schema)
    @test keys(defaults) === (:scalar, :buffer, :cell, :cells)
    @test defaults.scalar === 1.25f0
    @test defaults.buffer === buffer
    @test defaults.cell === cell
    @test defaults.cells === cells
    @test defaults.cells[1] === defaults.cell
    @test fieldtype(typeof(defaults), :scalar) === Float32
    @test fieldtype(typeof(defaults), :cell) === Base.RefValue{Any}
    @test fieldtype(typeof(defaults), :cells) === Vector{Base.RefValue{Any}}
    buffer[1] = 8f0
    cell[] = [9.0]
    next = @inferred PSE._input_default_values(schema)
    @test next.buffer === buffer
    @test next.buffer == Float32[8, 3]
    @test next.cell === cell
    @test next.cell[] isa Vector{Float64}
    @test defaults.cell[] === next.cell[]
    @test (@inferred PSE._input_default_values(NamedTuple())) === NamedTuple()
    @test (@inferred PSE._input_default_values((a=Required(Real), b=Required(AbstractVector)))) === NamedTuple()
end

function generic_default(value::T) where {T}
    return PSE._input_default_values((before=Required(Real),
        selected=Default(value), after=Required(T)))
end

@testset "wide concrete declarations infer every selected field" begin
    names = ntuple(index -> Symbol(:input_, index), 12)
    payload = Ref{Any}(Float32[12])
    declarations = (Required(Real), Default(1f0), Default(Int128(2)),
        Required(AbstractVector), Default(2 // 3), Default(payload),
        Required(Float32), Default(Float32[7]), Default(Int16(8)),
        Required(Number), Default((left=9f0,)), Default(:last))
    schema = NamedTuple{names}(declarations)
    defaults = @inferred PSE._input_default_values(schema)
    @test keys(defaults) === (names[2], names[3], names[5], names[6],
        names[8], names[9], names[11], names[12])
    @test defaults.input_2 === 1f0
    @test defaults.input_3 === Int128(2)
    @test defaults.input_5 === 2 // 3
    @test defaults.input_6 === payload
    @test defaults.input_8 === declarations[8].value
    @test defaults.input_9 === Int16(8)
    @test defaults.input_11 === (left=9f0,)
    @test defaults.input_12 === :last
    payload[] = :fresh
    @test (@inferred PSE._input_default_values(schema)).input_6[] === :fresh
end

@testset "generic numerical values retain their exact types" begin
    for value in (Float32(1.5), Int128(7), 2 // 3, big"1.25")
        defaults = @inferred generic_default(value)
        @test keys(defaults) === (:selected,)
        @test defaults.selected === value
        @test typeof(defaults.selected) === typeof(value)
    end
end

@testset "Any and union declarations select actual defaults without a type-based mask" begin
    AnySchema = NamedTuple{(:a, :b, :c, :d),Tuple{Any,Any,Any,Any}}
    payload = Float32[10]
    first = AnySchema((Required(Real), Default(2f0), nothing, Default(payload)))
    result = PSE._input_default_values(first)
    @test keys(result) === (:b, :d)
    @test result.b === 2f0
    @test result.d === payload
    second = AnySchema((Default(payload), Required(Float32), 3, :plain))
    result = PSE._input_default_values(second)
    @test keys(result) === (:a,)
    @test result.a === payload

    UnionSchema = NamedTuple{(:choice, :buffer),
        Tuple{Union{Required{Real},Default{Float32}},Default{Vector{Float32}}}}
    absent = UnionSchema((Required(Real), Default(payload)))
    present = UnionSchema((Default(3f0), Default(payload)))
    @test keys(PSE._input_default_values(absent)) === (:buffer,)
    @test PSE._input_default_values(absent).buffer === payload
    @test keys(PSE._input_default_values(present)) === (:choice, :buffer)
    @test PSE._input_default_values(present).choice === 3f0
    @test PSE._input_default_values(present).buffer === payload

    # This extraction helper historically skipped plain values. Validating an
    # inputs_ declaration remains the separate responsibility of _input_schema.
    @test PSE._input_default_values((plain=1.0, required=Required(Real),
        selected=Default(payload), marker=nothing)) == (selected=payload,)
end

@testset "fresh schema values are read once and never retained by extraction" begin
    reads = Ref(0)
    current = Ref{Any}(Float32[1])
    schema() = (reads[] += 1; (buffer=Default(current[]), required=Required(Real)))
    first_schema = schema()
    first = PSE._input_default_values(first_schema)
    @test reads[] == 1
    @test first.buffer === current[]
    current[] = Float64[2]
    next_schema = schema()
    next = PSE._input_default_values(next_schema)
    @test reads[] == 2
    @test first.buffer == Float32[1]
    @test next.buffer === current[]
    @test next.buffer isa Vector{Float64}
    @test PSE._input_default_values(first_schema).buffer === first.buffer
    @test reads[] == 2
end

PSE.@process "tuple_input_defaults" verbose=false
struct MutableInputDefaults{P} <: AbstractTuple_Input_DefaultsModel
    payload::P
end
PSE.inputs_(model::MutableInputDefaults) =
    (buffer=Default(model.payload[]), optional=Default(1f0))
PSE.outputs_(::MutableInputDefaults) = NamedTuple()
PSE.run!(::MutableInputDefaults, status, environment, constants, context) = nothing

@testset "canonical callers still copy fresh defaults for every real object" begin
    payload = Ref{Any}(Float32[1, 2])
    model = CompositeModel(Object(:first; scale=:Leaf), Object(:second; scale=:Leaf);
        applications=(ModelSpec(MutableInputDefaults(payload); name=:defaults,
            on=Many(scale=:Leaf)),))
    simulation = run!(model; steps=0, outputs=:none)
    first = model_status(model, :first).buffer
    second = model_status(model, :second).buffer
    @test first == second == Float32[1, 2]
    @test first !== second
    @test first !== payload[]
    payload[] = Float64[7, 8]
    register_object!(model, Object(:third; scale=:Leaf))
    step!(simulation)
    third = model_status(model, :third).buffer
    @test third == [7.0, 8.0]
    @test third isa Vector{Float64}
    @test third !== payload[]
    @test first isa Vector{Float32}
    @test second isa Vector{Float32}
    first[1] = 9f0
    @test second == Float32[1, 2]
    @test third == [7.0, 8.0]
    @test model_status(model, :third).optional === 1f0
end

end # module InputDefaultValuesChecks
