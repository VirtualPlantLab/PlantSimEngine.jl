using Dates
using PlantSimEngine

PlantSimEngine.@process "immutable_scenario_benchmark_source" verbose = false
struct ImmutableScenarioBenchmarkSource <:
       AbstractImmutable_Scenario_Benchmark_SourceModel end
PlantSimEngine.inputs_(::ImmutableScenarioBenchmarkSource) = NamedTuple()
PlantSimEngine.outputs_(::ImmutableScenarioBenchmarkSource) = (signal=0.0,)
function PlantSimEngine.run!(
    ::ImmutableScenarioBenchmarkSource,
    status,
    environment,
    constants=nothing,
    context=nothing,
)
    status.signal += 1.0
    return nothing
end

PlantSimEngine.@process "immutable_scenario_benchmark_consumer" verbose = false
struct ImmutableScenarioBenchmarkConsumer <:
       AbstractImmutable_Scenario_Benchmark_ConsumerModel end
PlantSimEngine.inputs_(::ImmutableScenarioBenchmarkConsumer) =
    (signals=Required(Vector{Float64}),)
PlantSimEngine.outputs_(::ImmutableScenarioBenchmarkConsumer) =
    (total=0.0,)
function PlantSimEngine.run!(
    ::ImmutableScenarioBenchmarkConsumer,
    status,
    environment,
    constants=nothing,
    context=nothing,
)
    status.total = sum(status.signals)
    return nothing
end

function _immutable_scenario_benchmark_outputs(output_policy)
    output_policy === :none && return :none
    output_policy === :all && return :all
    output_policy === :requests || throw(
        ArgumentError(
            "Unsupported immutable-scenario benchmark output policy " *
            "`$(output_policy)`.",
        ),
    )
    return OutputRequest(
        :Leaf,
        :signal;
        name=:leaf_signal,
        application=:leaf_signal,
        policy=HoldLast(),
        clock=Hour(1),
    )
end

function setup_immutable_scenario_benchmark(;
    nleaves::Int=256,
    output_policy=:none,
)
    nleaves > 0 || throw(ArgumentError("`nleaves` must be positive."))
    objects = Object[
        Object(
            :plant;
            scale=:Plant,
            kind=:plant,
            status=Status(signals=zeros(nleaves)),
        ),
    ]
    append!(
        objects,
        Object(
            Symbol(:leaf_, index);
            scale=:Leaf,
            kind=:leaf,
            parent=:plant,
        ) for index in 1:nleaves
    )
    model = CompositeModel(
        objects...;
        applications=(
            ModelSpec(
                ImmutableScenarioBenchmarkSource();
                name=:leaf_signal,
                on=Many(scale=:Leaf),
                every=Hour(1),
            ),
            ModelSpec(
                ImmutableScenarioBenchmarkConsumer();
                name=:daily_total,
                on=One(scale=:Plant),
                inputs=(
                    PreviousTimeStep(:signals) => Many(
                        scale=:Leaf,
                        within=Subtree(),
                        application=:leaf_signal,
                        var=:signal,
                    ),
                ),
                every=Day(1),
            ),
        ),
        environment=(duration=Hour(1),),
    )
    simulation = run!(
        model;
        steps=1,
        outputs=_immutable_scenario_benchmark_outputs(output_policy),
        performance=true,
    )
    return simulation
end

function benchmark_immutable_scenario_steps(simulation, nsteps::Int)
    nsteps >= 0 || throw(ArgumentError("`nsteps` must be non-negative."))
    return continue!(simulation; steps=nsteps)
end
