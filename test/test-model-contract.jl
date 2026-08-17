using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "contract_defaults" verbose = false

struct ContractDefaultsModel <: AbstractContract_DefaultsModel end
struct ContractExplicitModel <: AbstractContract_DefaultsModel end

PlantSimEngine.inputs_(::ContractDefaultsModel) = NamedTuple()
PlantSimEngine.outputs_(::ContractDefaultsModel) = (value=0,)
PlantSimEngine.inputs_(::ContractExplicitModel) = NamedTuple()
PlantSimEngine.outputs_(::ContractExplicitModel) = (value=0,)
PlantSimEngine.timespec(::Type{<:ContractExplicitModel}) = ClockSpec(2, 1)
PlantSimEngine.output_policy(::Type{<:ContractExplicitModel}) = (value=Aggregate(),)
PlantSimEngine.timestep_hint(::Type{<:ContractExplicitModel}) = (preferred=Dates.Hour(2),)
PlantSimEngine.environment_hint(::Type{<:ContractExplicitModel}) = (window=Dates.Hour(2),)
PlantSimEngine.environment_inputs_(::ContractExplicitModel) = (T=0,)
PlantSimEngine.environment_outputs_(::ContractExplicitModel) = (T=0,)

@testset "direct model trait defaults" begin
    model = ContractDefaultsModel()
    @test process(model) == :contract_defaults
    @test application_name(ModelSpec(model)) === nothing
    default_scene = CompositeModel(model)
    @test only(explain_applications(Advanced.refresh_bindings!(default_scene))).application_id ==
          :contract_defaults
    @test timespec(model) == ClockSpec(1.0, 0.0)
    @test output_policy(model) == NamedTuple()
    @test timestep_hint(model) === nothing
    @test environment_hint(model) === nothing
    @test PlantSimEngine.environment_inputs_(model) == NamedTuple()
    @test PlantSimEngine.environment_outputs_(model) == NamedTuple()

    explicit = ContractExplicitModel()
    @test timespec(explicit) == ClockSpec(2, 1)
    @test output_policy(explicit).value isa Aggregate
    @test timestep_hint(explicit) == (preferred=Dates.Hour(2),)
    @test environment_hint(explicit) == (window=Dates.Hour(2),)
    @test PlantSimEngine.environment_inputs_(explicit) == (T=0,)
    @test PlantSimEngine.environment_outputs_(explicit) == (T=0,)
end
