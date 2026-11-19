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
    # Each CompositeModel prepares one numerical configuration. Exercise both
    # Float32 and Float64 without changing that configuration between births.
    for T in (Float32, Float64)
        payload = Ref{Any}(T[1, 2])
        model = CompositeModel(Object(:first; scale=:Leaf), Object(:second; scale=:Leaf);
            applications=(ModelSpec(MutableInputDefaults(payload); name=:defaults,
                on=Many(scale=:Leaf)),))
        simulation = run!(model; steps=0, outputs=:none)
        first = model_status(model, :first).buffer
        second = model_status(model, :second).buffer
        @test first == second == T[1, 2]
        @test first !== second
        @test first !== payload[]
        payload[] = T[7, 8]
        register_object!(model, Object(:third; scale=:Leaf))
        step!(simulation)
        third = model_status(model, :third).buffer
        @test third == T[7, 8]
        @test third isa Vector{T}
        @test third !== payload[]
        @test first isa Vector{T}
        @test second isa Vector{T}
        first[1] = T(9)
        @test second == T[1, 2]
        @test third == T[7, 8]
        @test model_status(model, :third).optional === 1f0
    end
end

struct AbstractMutableInputDefaults{T,P} <: AbstractTuple_Input_DefaultsModel
    payload::P
end
PSE.inputs_(model::AbstractMutableInputDefaults{T}) where {T} =
    (selected=Default{T}(model.payload[]),)
PSE.outputs_(::AbstractMutableInputDefaults) = NamedTuple()
PSE.run!(::AbstractMutableInputDefaults, status, environment, constants, context) = nothing

@testset "fresh abstract defaults preserve values and prepared cells" begin
    required = (required=Required(Integer),)
    witness = PSE._authored_port_types(typeof, required)
    admitted = @inferred PSE._admit_authored_port_schema(required, witness, Val(:inputs))
    @test (@inferred PSE._input_default_values(admitted)) === NamedTuple()
    for T in (Real, Any)
        payload = Ref{T}(1f0)
        process = AbstractMutableInputDefaults{T,typeof(payload)}(payload)
        model = CompositeModel(Object(:first; scale=:Leaf);
            applications=(ModelSpec(process; name=:defaults, on=Many(scale=:Leaf)),))
        simulation = run!(model; steps=0, outputs=:none)
        application = simulation.compiled.applications_by_id[:defaults]
        first = PSE.refvalue(model_status(model, :first), :selected)
        @test first[] === 1f0
        payload[] = 3.25
        defaults = PSE._application_default_schemas(application, Val(:inputs))
        @test defaults.selected === payload[]
        @test isequal(defaults.selected, payload[])
        @test typeof(defaults.selected) === Float64
        raw = PSE.inputs_(process)
        admitted = PSE._admit_authored_port_schema(raw,
            PSE._application_ports(application).input_declaration_types, Val(:inputs))
        @test admitted.selected.value === payload[]
        # The scene prepared Float32 cells; keep the actual birth in that family.
        payload[] = 3.25f0
        register_object!(model, Object(:second; scale=:Leaf))
        step!(simulation)
        @test model_status(model, :second).selected == 3.25
        @test PSE.refvalue(model_status(model, :first), :selected) === first
        @test first[] === 1f0
    end
end

struct ErasedAuthoredDeclarations <: AbstractTuple_Input_DefaultsModel
    input::Base.RefValue{Any}
    output::Base.RefValue{Any}
    input_reads::Base.RefValue{Int}
    output_reads::Base.RefValue{Int}
end
function PSE.inputs_(model::ErasedAuthoredDeclarations)
    model.input_reads[] += 1
    return model.input[]
end
function PSE.outputs_(model::ErasedAuthoredDeclarations)
    model.output_reads[] += 1
    return model.output[]
end
PSE.run!(::ErasedAuthoredDeclarations, status, environment, constants, context) = nothing

@testset "erased configured declarations retain fresh payloads and hook diagnostics" begin
    input_name, output_name = Symbol("configured_", "input"), Symbol("configured_", "output")
    input_schema = value -> NamedTuple{(input_name,:buffer,:required),Tuple{Any,Any,Any}}(
        (Default{Real}(value), Default(Float32[1,2]), Required(Integer)))
    output_schema = value -> NamedTuple{(output_name,),Tuple{Any}}((value,))
    process = ErasedAuthoredDeclarations(Ref{Any}(input_schema(1f0)),
        Ref{Any}(output_schema(Float32[1])), Ref(0), Ref(0))
    model = CompositeModel(Object(:leaf; scale=:Leaf, status=Status((required=1,)));
        applications=(ModelSpec(process; name=:defaults, on=Many(scale=:Leaf)),))
    simulation = run!(model; steps=0, outputs=:none)
    application = simulation.compiled.applications_by_id[:defaults]
    process.input[] = input_schema(3.25)
    buffer = process.input[].buffer.value
    process.input_reads[] = 0
    defaults = PSE._application_default_schemas(application, Val(:inputs))
    @test process.input_reads[] == 1
    @test isequal(getproperty(defaults,input_name), 3.25)
    @test typeof(getproperty(defaults,input_name)) === Float64
    @test defaults.buffer === buffer
    fresh_output = Float32[4,5]
    process.output[] = output_schema(fresh_output)
    process.output_reads[] = 0
    @test getproperty(PSE._application_default_schemas(application, Val(:outputs)), output_name) === fresh_output
    @test process.output_reads[] == 1

    caught(operation) = try operation(); nothing catch error; error end
    invalid_inputs = (1, NamedTuple{(input_name,:buffer,:required),Tuple{Any,Any,Any}}(
        (2, Default(Float32[1]), Required(Integer))))
    for invalid in invalid_inputs
        # A malformed declaration at construction keeps its detailed diagnostic
        # and is frozen without replaying the hook during activation.
        broken = ErasedAuthoredDeclarations(Ref{Any}(invalid),
            Ref{Any}(output_schema(Float32[1])), Ref(0), Ref(0))
        expected = caught(() -> PSE._input_schema(broken))
        broken.input_reads[] = 0
        failed = CompositeModel(Object(:leaf; scale=:Leaf, status=Status((required=1,)));
            applications=(ModelSpec(broken; name=:defaults, on=Many(scale=:Leaf)),))
        @test broken.input_reads[] == 1
        failure = failed.scenario_plan_cache.failure
        @test failure isa PSE.ScenarioPreparationFailure
        @test typeof(failure.error) === typeof(expected)
        @test sprint(showerror,failure.error) == sprint(showerror,expected)
        @test_throws ErrorException run!(failed; steps=0)
        @test broken.input_reads[] == 1
    end
    changed_name = NamedTuple{(:changed,:buffer,:required),Tuple{Any,Any,Any}}(
        (Default{Real}(3.25), Default(Float32[1]), Required(Integer)))
    for changed in (invalid_inputs..., changed_name)
        process.input[] = changed
        process.input_reads[] = 0
        actual = caught(() -> PSE._application_default_schemas(application, Val(:inputs)))
        @test process.input_reads[] == 1
        @test actual isa ArgumentError
        message = sprint(showerror,actual)
        @test occursin("inputs_", message)
        @test all(name -> occursin(string(name),message), (input_name,:buffer,:required))
        @test occursin("after preparation", message)
    end
    broken_output = ErasedAuthoredDeclarations(Ref{Any}(input_schema(1f0)),
        Ref{Any}(1), Ref(0), Ref(0))
    broken_spec = ModelSpec(broken_output; name=:defaults, on=Many(scale=:Leaf))
    expected = caught(() -> PSE._output_schema(broken_spec))
    broken_output.output_reads[] = 0
    failed_output = CompositeModel(Object(:leaf; scale=:Leaf);
        applications=(broken_spec,))
    @test broken_output.output_reads[] == 1
    failure = failed_output.scenario_plan_cache.failure
    @test failure isa PSE.ScenarioPreparationFailure
    @test failure.error isa ArgumentError
    @test sprint(showerror,failure.error) == sprint(showerror,expected)
    @test_throws ArgumentError run!(failed_output; steps=0)
    @test broken_output.output_reads[] == 1
    process.output[] = 1
    process.output_reads[] = 0
    actual = caught(() -> PSE._application_default_schemas(application, Val(:outputs)))
    @test process.output_reads[] == 1
    @test actual isa ArgumentError
    @test occursin("outputs_", sprint(showerror,actual))
    @test occursin(string(output_name), sprint(showerror,actual))
end

end # module InputDefaultValuesChecks
