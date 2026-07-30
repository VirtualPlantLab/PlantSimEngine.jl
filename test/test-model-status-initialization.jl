using PlantSimEngine
using Test

PlantSimEngine.@process "initialization_source" verbose = false
PlantSimEngine.@process "initialization_consumer" verbose = false

struct InitializationSourceModel <: AbstractInitialization_SourceModel end
struct InitializationConsumerModel <: AbstractInitialization_ConsumerModel end

PlantSimEngine.inputs_(::InitializationSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::InitializationSourceModel) = (signal=1,)
function PlantSimEngine.run!(::InitializationSourceModel, status, environment, constants, context)
    status.signal += 1
end

PlantSimEngine.inputs_(::InitializationConsumerModel) = (
    signal=Required(Int),
    supplied=Required(Int),
    offset=Default(0),
)
PlantSimEngine.outputs_(::InitializationConsumerModel) = (observed=0,)
function PlantSimEngine.run!(::InitializationConsumerModel, status, environment, constants, context)
    status.observed = status.signal + status.supplied + status.offset
end

@testset "generated and partial status" begin
    model = CompositeModel(
        Object(:object; scale=:Leaf, status=Status(supplied=40));
        applications=(
            ModelSpec(InitializationSourceModel(); name=:source) |> AppliesTo(One(scale=:Leaf)),
            ModelSpec(InitializationConsumerModel(); name=:consumer) |> AppliesTo(One(scale=:Leaf)),
        ),
    )
    compiled = Advanced.refresh_bindings!(model)
    status = only(model_objects(model)).status
    @test status.supplied == 40
    @test Set(propertynames(status)) == Set((:supplied, :signal, :offset, :observed))
    @test status.offset == 0
    binding = only(row for row in compiled.input_bindings if row.input == :signal)
    @test PlantSimEngine.refvalue(status, :signal) === input_carrier(binding)
    report = explain_initialization(model)
    @test only(row for row in report if row.variable == :supplied && row.role == :input).disposition == :supplied
    @test only(row for row in report if row.variable == :signal && row.role == :input).disposition == :producer_bound
    default_row = only(row for row in report if row.variable == :offset && row.role == :input)
    @test default_row.disposition == :defaulted
    @test default_row.declaration == :defaulted
    @test default_row.default_value == 0
    run!(model)
    @test status.observed == 42

    unresolved = CompositeModel(InitializationConsumerModel(); status=(supplied=1,))
    @test isnothing(only(model_objects(unresolved)).kind)
    unresolved_report = explain_initialization(unresolved)
    @test any(row -> row.variable == :signal && row.disposition == :required,
              unresolved_report)
    @test any(row -> row.variable == :offset && row.disposition == :defaulted,
              unresolved_report)
    @test_throws "Missing required composite-model/object input" run!(unresolved)
end

PlantSimEngine.@process "invalid_initialization_schema" verbose = false
PlantSimEngine.@process "default_vector_initialization" verbose = false
struct InvalidInitializationSchemaModel <: AbstractInvalid_Initialization_SchemaModel end
struct DefaultVectorInitializationModel <: AbstractDefault_Vector_InitializationModel end
PlantSimEngine.inputs_(::InvalidInitializationSchemaModel) = (legacy_literal=0.0,)
PlantSimEngine.outputs_(::InvalidInitializationSchemaModel) = NamedTuple()
PlantSimEngine.inputs_(::DefaultVectorInitializationModel) = (buffer=Default(Int[]),)
PlantSimEngine.outputs_(::DefaultVectorInitializationModel) = NamedTuple()

@testset "explicit input declarations" begin
    @test inputs(InitializationConsumerModel()) == (:signal, :supplied, :offset)
    @test init_variables(InitializationConsumerModel()) == (offset=0, observed=0)
    typed = PlantSimEngine.variables_typed(InitializationConsumerModel())
    @test typed.signal == Int
    @test typed.supplied == Int
    @test typed.offset == Int
    @test typed.observed == Int
    invalid = CompositeModel(
        InvalidInitializationSchemaModel();
        status=(legacy_literal=1.0,),
    )
    @test_throws "must make every input explicit" Advanced.refresh_bindings!(invalid)

    private_defaults = CompositeModel(
        Object(:leaf_1; scale=:Leaf),
        Object(:leaf_2; scale=:Leaf);
        applications=(
            ModelSpec(DefaultVectorInitializationModel(); name=:default_vector) |>
            AppliesTo(Many(scale=:Leaf)),
        ),
    )
    Advanced.refresh_bindings!(private_defaults)
    buffers = [object.status.buffer for object in model_objects(private_defaults)]
    @test buffers[1] !== buffers[2]
    push!(buffers[1], 1)
    @test isempty(buffers[2])

    optional_default = CompositeModel(
        Object(
            :leaf;
            scale=:Leaf,
            status=Status(signal=1, supplied=2),
        );
        applications=(
            ModelSpec(InitializationConsumerModel(); name=:consumer) |>
            AppliesTo(One(scale=:Leaf)) |>
            Inputs(:offset => OptionalOne(scale=:Soil, var=:offset)),
        ),
    )
    optional_row = only(
        row for row in explain_initialization(optional_default)
        if row.role == :input && row.variable == :offset
    )
    @test optional_row.disposition == :defaulted
    @test optional_row.origin == :model_default
end
