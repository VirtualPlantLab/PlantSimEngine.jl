using PlantSimEngine
using Test

PlantSimEngine.@process "initialization_source" verbose = false
PlantSimEngine.@process "initialization_consumer" verbose = false

struct InitializationSourceModel <: AbstractInitialization_SourceModel end
struct InitializationConsumerModel <: AbstractInitialization_ConsumerModel end

PlantSimEngine.inputs_(::InitializationSourceModel) = NamedTuple()
PlantSimEngine.outputs_(::InitializationSourceModel) = (signal=1,)
function PlantSimEngine.run!(::InitializationSourceModel, models, status, meteo, constants, extra)
    status.signal += 1
end

PlantSimEngine.inputs_(::InitializationConsumerModel) = (signal=0, supplied=0)
PlantSimEngine.outputs_(::InitializationConsumerModel) = (observed=0,)
function PlantSimEngine.run!(::InitializationConsumerModel, models, status, meteo, constants, extra)
    status.observed = status.signal + status.supplied
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
    @test Set(propertynames(status)) == Set((:supplied, :signal, :observed))
    binding = only(row for row in compiled.input_bindings if row.input == :signal)
    @test PlantSimEngine.refvalue(status, :signal) === input_carrier(binding)
    report = explain_initialization(model)
    @test only(row for row in report if row.variable == :supplied && row.role == :input).disposition == :supplied
    @test only(row for row in report if row.variable == :signal && row.role == :input).disposition == :producer_bound
    run!(model)
    @test status.observed == 42

    unresolved = CompositeModel(InitializationConsumerModel(); status=(supplied=1,))
    @test any(row -> row.variable == :signal && row.disposition == :unresolved,
              explain_initialization(unresolved))
    @test_throws "Missing required composite-model/object input" run!(unresolved)
end
