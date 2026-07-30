using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "parity_forcing" verbose = false
PlantSimEngine.@process "parity_stage_one" verbose = false
PlantSimEngine.@process "parity_stage_two" verbose = false
PlantSimEngine.@process "parity_stage_three" verbose = false

struct ParityForcingModel <: AbstractParity_ForcingModel end
struct ParityStageOneModel{T} <: AbstractParity_Stage_OneModel
    a::T
end
struct ParityStageTwoModel <: AbstractParity_Stage_TwoModel end
struct ParityStageThreeModel <: AbstractParity_Stage_ThreeModel end

PlantSimEngine.@process "parity_stage_five" verbose = false
PlantSimEngine.@process "parity_stage_six" verbose = false
PlantSimEngine.@process "parity_soil" verbose = false
PlantSimEngine.@process "parity_gather" verbose = false
PlantSimEngine.@process "parity_receiver" verbose = false

struct ParityStageFiveModel <: AbstractParity_Stage_FiveModel end
struct ParityStageSixModel <: AbstractParity_Stage_SixModel end
struct ParitySoilModel <: AbstractParity_SoilModel end
struct ParityGatherModel <: AbstractParity_GatherModel end
struct ParityReceiverModel <: AbstractParity_ReceiverModel end

PlantSimEngine.inputs_(::ParityForcingModel) = NamedTuple()
PlantSimEngine.outputs_(::ParityForcingModel) = (var1=0.0,)
PlantSimEngine.environment_inputs_(::ParityForcingModel) = (forcing=0.0,)
function PlantSimEngine.run!(::ParityForcingModel, status, environment, constants, context)
    status.var1 = environment.forcing
    return nothing
end

PlantSimEngine.inputs_(::ParityStageOneModel) = (var1=Required(Float64), var2=Required(Float64))
PlantSimEngine.outputs_(::ParityStageOneModel) = (var3=0.0,)
function PlantSimEngine.run!(model::ParityStageOneModel, status, environment, constants, context)
    status.var3 = model.a + status.var1 * status.var2
    return nothing
end

PlantSimEngine.inputs_(::ParityStageTwoModel) = (var3=Required(Float64),)
PlantSimEngine.outputs_(::ParityStageTwoModel) = (raw_var4=0.0, var5=0.0)
PlantSimEngine.environment_inputs_(::ParityStageTwoModel) = (T=0.0, Wind=0.0, Rh=0.0)
function PlantSimEngine.run!(::ParityStageTwoModel, status, environment, constants, context)
    status.raw_var4 = status.var3 * 2
    status.var5 = status.raw_var4 + environment.T + 2 * environment.Wind + 3 * environment.Rh
    return nothing
end

PlantSimEngine.inputs_(::ParityStageThreeModel) = (raw_var4=Required(Float64), var5=Required(Float64))
PlantSimEngine.outputs_(::ParityStageThreeModel) = (var4=0.0, var6=0.0)
function PlantSimEngine.run!(::ParityStageThreeModel, status, environment, constants, context)
    status.var4 = status.raw_var4 * 2
    status.var6 = status.var5 + status.var4
    return nothing
end

PlantSimEngine.inputs_(::ParityStageFiveModel) = (var5=Required(Float64), var6=Required(Float64))
PlantSimEngine.outputs_(::ParityStageFiveModel) = (var7=0.0,)
function PlantSimEngine.run!(::ParityStageFiveModel, status, environment, constants, context)
    status.var7 = status.var5 * status.var6
end
PlantSimEngine.inputs_(::ParityStageSixModel) = (var7=Required(Float64),)
PlantSimEngine.outputs_(::ParityStageSixModel) = (var8=0.0,)
function PlantSimEngine.run!(::ParityStageSixModel, status, environment, constants, context)
    status.var8 = status.var7 + 1
end
PlantSimEngine.inputs_(::ParitySoilModel) = NamedTuple()
PlantSimEngine.outputs_(::ParitySoilModel) = (soil_value=1.0,)
PlantSimEngine.run!(::ParitySoilModel, status, environment, constants, context) = nothing
PlantSimEngine.inputs_(::ParityGatherModel) = (leaf_values=Required(Vector{Float64}), soil_value=Required(Float64))
PlantSimEngine.outputs_(::ParityGatherModel) = (gathered=0.0, scattered=0.0)
function PlantSimEngine.run!(::ParityGatherModel, status, environment, constants, context)
    status.gathered = sum(status.leaf_values) + status.soil_value
    status.scattered = first(status.leaf_values)
end
PlantSimEngine.inputs_(::ParityReceiverModel) = (shared=Required(Float64),)
PlantSimEngine.outputs_(::ParityReceiverModel) = (received=0.0,)
function PlantSimEngine.run!(::ParityReceiverModel, status, environment, constants, context)
    status.received = status.shared
end

parity_weather = [
    (forcing=15.0, T=20.0, Wind=1.0, Rh=0.65, duration=Hour(1)),
    (forcing=16.0, T=25.0, Wind=0.5, Rh=0.8, duration=Hour(1)),
]

function parity_applications(selector)
    return (
        ModelSpec(ParityForcingModel(); name=:forcing) |> AppliesTo(selector),
        ModelSpec(ParityStageOneModel(1.0); name=:stage_one) |> AppliesTo(selector),
        ModelSpec(ParityStageTwoModel(); name=:stage_two) |> AppliesTo(selector),
        ModelSpec(ParityStageThreeModel(); name=:stage_three) |> AppliesTo(selector),
    )
end

function parity_state(status)
    return [status.var5, status.var4, status.var6, status.var1, status.var3, status.var2]
end

@testset "exact one-object process chain" begin
    one_step = CompositeModel(
        Object(:leaf; scale=:Leaf, status=Status(var2=0.3));
        applications=parity_applications(One(scale=:Leaf)),
        environment=parity_weather[1:1],
    )
    run!(one_step)
    @test parity_state(only(model_objects(one_step)).status) == [34.95, 22.0, 56.95, 15.0, 5.5, 0.3]

    two_steps = CompositeModel(
        Object(:leaf; scale=:Leaf, status=Status(var2=0.3));
        applications=parity_applications(One(scale=:Leaf)),
        environment=parity_weather,
    )
    simulation = run!(two_steps; steps=2, outputs=:all)
    @test parity_state(only(model_objects(two_steps)).status) == [40.0, 23.2, 63.2, 16.0, 5.8, 0.3]
    @test last.(outputs(simulation)[(:stage_three, ObjectId(:leaf), :var6)]) == [56.95, 63.2]
end

@testset "one application with an object-specific Override" begin
    template = CompositeModelTemplate(
        parity_applications(Many(scale=:Leaf));
        kind=:plant,
    )
    instance = ObjectInstance(
        :plant,
        template;
        root=Object(:plant; scale=:Plant),
        objects=(
            Object(:leaf_default; scale=:Leaf, parent=:plant, status=Status(var2=0.3)),
            Object(:leaf_override; scale=:Leaf, parent=:plant, status=Status(var2=0.3)),
        ),
        object_overrides=(
            Override(
                object=:leaf_override,
                application=:stage_one,
                model=ParityStageOneModel(2.0),
            ),
        ),
    )
    model = CompositeModel(instance; environment=parity_weather)
    simulation = run!(model; steps=2, outputs=:all)
    statuses = Dict(object.id.value => object.status for object in model_objects(model))
    @test parity_state(statuses[:leaf_default]) == [40.0, 23.2, 63.2, 16.0, 5.8, 0.3]
    @test parity_state(statuses[:leaf_override]) == [42.0, 27.2, 69.2, 16.0, 6.8, 0.3]

    override_rows = filter(
        row -> row.object_id == :leaf_override && row.variable in (:var5, :var4, :var6),
        collect_outputs(simulation; sink=nothing),
    )
    @test length(override_rows) == 6
end


@testset "exact multiscale gather and scatter chain" begin
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:soil; scale=:Soil, parent=:scene),
        Object(:plant; scale=:Plant, parent=:scene),
        Object(:internode_1; scale=:Internode, parent=:plant),
        Object(:leaf_1; scale=:Leaf, parent=:internode_1, status=Status(var2=1.03)),
        Object(:internode_2; scale=:Internode, parent=:internode_1),
        Object(:leaf_2; scale=:Leaf, parent=:internode_2, status=Status(var2=1.03));
        applications=(
            ModelSpec(ParitySoilModel(); name=:soil_source) |>
                AppliesTo(One(scale=:Soil)),
            ModelSpec(ParityForcingModel(); name=:forcing) |>
                AppliesTo(Many(scale=:Leaf)),
            ModelSpec(ParityStageOneModel(1.0); name=:stage_one) |>
                AppliesTo(Many(scale=:Leaf)),
            ModelSpec(ParityStageTwoModel(); name=:stage_two) |>
                AppliesTo(Many(scale=:Leaf)),
            ModelSpec(ParityStageThreeModel(); name=:stage_three) |>
                AppliesTo(Many(scale=:Leaf)),
            ModelSpec(ParityStageFiveModel(); name=:stage_five) |>
                AppliesTo(Many(scale=:Leaf)),
            ModelSpec(ParityStageSixModel(); name=:stage_six) |>
                AppliesTo(Many(scale=:Leaf)),
            ModelSpec(ParityGatherModel(); name=:plant_gather) |>
                AppliesTo(One(scale=:Plant)) |>
                Inputs(
                    :leaf_values => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:stage_six,
                        var=:var8,
                    ),
                    :soil_value => One(
                        scale=:Soil,
                        within=SceneScope(),
                        application=:soil_source,
                        var=:soil_value,
                    ),
                ),
            ModelSpec(ParityReceiverModel(); name=:leaf_receiver) |>
                AppliesTo(Many(scale=:Leaf)) |>
                Inputs(:shared => One(
                    scale=:Plant,
                    within=Ancestor(scale=:Plant),
                    application=:plant_gather,
                    var=:scattered,
                )),
            ModelSpec(ParityReceiverModel(); name=:internode_receiver) |>
                AppliesTo(Many(scale=:Internode)) |>
                Inputs(:shared => One(
                    scale=:Plant,
                    within=Ancestor(scale=:Plant),
                    application=:plant_gather,
                    var=:scattered,
                )),
        ),
        environment=[
            (forcing=1.01, T=20.0, Wind=1.0, Rh=0.65, duration=Hour(1)),
            (forcing=1.01, T=25.0, Wind=0.5, Rh=0.8, duration=Hour(1)),
        ],
    )
    simulation = run!(model; steps=2, outputs=:all)
    leaves = model_objects(model; scale=:Leaf)
    @test getproperty.(leaves, :id) == [ObjectId(:leaf_1), ObjectId(:leaf_2)]
    for leaf in leaves
        @test leaf.status.var1 === 1.01
        @test leaf.status.var2 === 1.03
        @test leaf.status.var4 ≈ 8.1612000000000013 atol=1e-6
        @test leaf.status.var5 == 32.4806
        @test leaf.status.var8 ≈ 1321.0700490800002 atol=1e-6
        @test leaf.status.received == leaf.status.var8
    end
    plant = only(model_objects(model; scale=:Plant)).status
    @test plant.gathered ≈ 2 * 1321.0700490800002 + 1 atol=1e-6
    @test all(
        object -> object.status.received ≈ 1321.0700490800002,
        model_objects(model; scale=:Internode),
    )
    rows = filter(row -> row.variable == :var8, collect_outputs(simulation; sink=nothing))
    @test length(rows) == 4
    @test Set(getproperty.(rows, :object_id)) == Set((:leaf_1, :leaf_2))
end
