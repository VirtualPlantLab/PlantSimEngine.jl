using Dates
using PlantSimEngine
using PlantSimEngine.Diagnostics
using Test

PlantSimEngine.@process "status_type_conversion" verbose = false

struct StatusTypeConversionModel <: AbstractStatus_Type_ConversionModel end

PlantSimEngine.inputs_(::StatusTypeConversionModel) = (
    supplied=Required(Real),
    offset=Default(0.5),
    default_vector=Default([1.0, 2.0]),
)

PlantSimEngine.outputs_(::StatusTypeConversionModel) = (
    result=0.0,
    default_matrix=reshape([1.0, 2.0, 3.0, 4.0], 2, 2),
    count=1,
)

function PlantSimEngine.run!(
    ::StatusTypeConversionModel,
    status,
    environment,
    constants,
    context,
)
    status.result = status.supplied + status.offset
    return nothing
end

struct StatusTransformParticle{T}
    value::T
    spread::T
end

struct StatusTransformCallable end

struct StatusTransformContainer{T}
    values::T
end

function (::StatusTransformCallable)(variable, value)
    variable === :uncertain || return value
    return StatusTransformParticle(value, value / 10)
end

@testset "source Status identity remains exclusive under conversion" begin
    shared = Status(value=1.0)
    @test_throws ArgumentError CompositeModel(
        Object(:first; status=shared),
        Object(:second; status=shared);
        type_promotion=Dict(Float64 => Float32),
    )

    model = CompositeModel(
        Object(:first; status=shared);
        type_promotion=Dict(Float64 => Float32),
    )
    @test_throws ArgumentError register_object!(
        model,
        Object(:second; status=shared),
    )
end

@testset "no status conversion policy preserves current values and references" begin
    original = Status(supplied=1.25, untouched=2)
    supplied_reference = PlantSimEngine.refvalue(original, :supplied)
    object = Object(:scene; scale=:Scene, status=original)
    model = CompositeModel(
        object;
        applications=(
            ModelSpec(
                StatusTypeConversionModel();
                name=:conversion,
                on=One(scale=:Scene),
            ),
        ),
    )

    @test object.status === original
    @test PlantSimEngine.refvalue(object.status, :supplied) === supplied_reference
    Advanced.refresh_bindings!(model)
    @test object.status.supplied isa Float64
    @test object.status.offset isa Float64
    @test object.status.result isa Float64
    @test eltype(object.status.default_vector) === Float64
end

@testset "Float64 status values materialize as Float32" begin
    model = CompositeModel(
        StatusTypeConversionModel();
        status=(
            supplied=1.25,
            explicit_vector=[3.0, 4.0],
            explicit_matrix=reshape([5.0, 6.0], 1, 2),
            count_from_user=2,
            flag=true,
            label=:leaf,
            label_text="leaf",
            date=Date(2026, 8, 26),
            cadence=Hour(1),
        ),
        type_promotion=Dict(Float64 => Float32),
    )

    compiled = Advanced.refresh_bindings!(model)
    status = only(model_objects(model)).status

    @test status.supplied isa Float32
    @test status.offset isa Float32
    @test status.result isa Float32
    @test status.explicit_vector isa Vector{Float32}
    @test status.explicit_matrix isa Matrix{Float32}
    @test status.default_vector isa Vector{Float32}
    @test status.default_matrix isa Matrix{Float32}
    @test status.count === 1
    @test status.count_from_user === 2
    @test status.flag === true
    @test status.label === :leaf
    @test status.label_text == "leaf"
    @test status.date === Date(2026, 8, 26)
    @test status.cadence === Hour(1)
    @test only(Diagnostics.explain_execution_plan(model)).status_type ==
          typeof(status)

    simulation = run!(model; outputs=:all)
    @test status.result === Float32(1.75)
    @test all(
        fieldtype(eltype(stream), 2) === Float32
        for ((_, _, variable), stream) in outputs(simulation)
        if variable === :result
    )

    initialization = Diagnostics.explain_initialization(model)
    supplied_row = only(
        row for row in initialization
        if row.role === :input && row.variable === :supplied
    )
    offset_row = only(
        row for row in initialization
        if row.role === :input && row.variable === :offset
    )
    result_row = only(
        row for row in initialization
        if row.role === :output && row.variable === :result
    )
    @test supplied_row.declared_type === Real
    @test supplied_row.original_type === Float64
    @test supplied_row.effective_type === Float32
    @test supplied_row.type_mapping_applied
    @test supplied_row.type_mapping_rule == (Float64 => Float32)
    @test offset_row.declared_type === Float64
    @test offset_row.original_type === Float64
    @test offset_row.effective_type === Float32
    @test result_row.declared_type === Float64
    @test result_row.original_type === Float64
    @test result_row.effective_type === Float32
end

@testset "numeric arrays preserve shape and unrelated values" begin
    model = CompositeModel(
        Object(
            :scene;
            status=Status(
                empty_vector=Float64[],
                empty_matrix=reshape(Float64[], 0, 2),
                mixed=Real[1.0, 2],
                custom=StatusTransformContainer([3.0, 4.0]),
            ),
        );
        type_promotion=Dict(Float64 => Float32),
    )
    status = only(model_objects(model)).status

    @test status.empty_vector isa Vector{Float32}
    @test status.empty_matrix isa Matrix{Float32}
    @test size(status.empty_matrix) == (0, 2)
    @test status.mixed isa Vector{Real}
    @test status.mixed[1] isa Float32
    @test status.mixed[2] isa Int
    @test status.custom isa StatusTransformContainer{Vector{Float64}}
end

@testset "initialization diagnostics record precise transforms" begin
    transform = (variable, value) ->
        variable === :supplied ? BigFloat(value) : value
    model = CompositeModel(
        StatusTypeConversionModel();
        status=(supplied=1.25,),
        type_promotion=Dict(Float64 => Float32),
        status_transform=transform,
    )
    initialization = Diagnostics.explain_initialization(model)
    supplied_row = only(
        row for row in initialization
        if row.role === :input && row.variable === :supplied
    )

    @test supplied_row.original_type === Float64
    @test supplied_row.transformed_type === BigFloat
    @test supplied_row.effective_type === BigFloat
    @test supplied_row.status_transform_applied
    @test supplied_row.status_transform_changed
    @test !supplied_row.type_mapping_applied
end

@testset "precise transform runs before the general type mapping" begin
    model = CompositeModel(
        Object(
            :scene;
            scale=:Scene,
            status=Status(uncertain=10.0, ordinary=20.0, count=3),
        );
        type_promotion=Dict(Float64 => Float32),
        status_transform=StatusTransformCallable(),
    )
    status = only(model_objects(model)).status

    @test status.uncertain == StatusTransformParticle(10.0, 1.0)
    @test status.uncertain isa StatusTransformParticle{Float64}
    @test status.ordinary === Float32(20)
    @test status.count === 3
end

@testset "type rule selection is deterministic" begin
    exact = CompositeModel(
        Object(:scene; status=Status(value=1.0));
        type_promotion=Dict(
            AbstractFloat => Float16,
            Float64 => Float32,
        ),
    )
    @test only(model_objects(exact)).status.value isa Float32

    specific = CompositeModel(
        Object(:scene; status=Status(value=1.0));
        type_promotion=Dict(
            Real => Float16,
            AbstractFloat => Float32,
        ),
    )
    @test only(model_objects(specific)).status.value isa Float32

    ambiguous_rules = Dict{Any,Any}(
        Union{Float64,Int} => Float32,
        Union{Float64,String} => Float16,
    )
    exception = try
        CompositeModel(
            Object(:scene);
            type_promotion=ambiguous_rules,
        )
        nothing
    catch error
        error
    end
    @test exception isa ErrorException
    @test occursin("Ambiguous `type_promotion` rules", sprint(showerror, exception))
    @test occursin("Float64", sprint(showerror, exception))
end

@testset "invalid mappings and conversions fail with context" begin
    @test_throws "source keys must be types" CompositeModel(
        Object(:scene);
        type_promotion=Dict(:Float64 => Float32),
    )
    @test_throws "target values must be types" CompositeModel(
        Object(:scene);
        type_promotion=Dict(Float64 => :Float32),
    )

    exception = try
        CompositeModel(
            Object(:leaf; status=Status(biomass=1.0));
            type_promotion=Dict(Float64 => String),
        )
        nothing
    catch error
        error
    end
    message = sprint(showerror, exception)
    @test occursin("Failed to apply `type_promotion`", message)
    @test occursin("`biomass`", message)
    @test occursin("object `leaf`", message)
    @test occursin("Float64", message)
    @test occursin("String", message)
end
