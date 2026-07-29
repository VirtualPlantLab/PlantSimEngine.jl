using Dates
using PlantSimEngine
using Test

PlantSimEngine.@process "runtime_matrix_probe" verbose = false
struct RuntimeMatrixProbeModel <: AbstractRuntime_Matrix_ProbeModel end
PlantSimEngine.inputs_(::RuntimeMatrixProbeModel) = NamedTuple()
PlantSimEngine.outputs_(::RuntimeMatrixProbeModel) = (seen=0.0,)
PlantSimEngine.environment_inputs_(::RuntimeMatrixProbeModel) = (T=0.0,)
function PlantSimEngine.run!(::RuntimeMatrixProbeModel, status, environment, constants, context)
    status.seen = environment.T
end

function runtime_matrix_scene(environment)
    return CompositeModel(
        Object(:probe; scale=:Leaf);
        applications=(
            ModelSpec(RuntimeMatrixProbeModel(); name=:probe) |>
                AppliesTo(One(scale=:Leaf)),
        ),
        environment=environment,
    )
end

@testset "environment and output request matrix" begin
    constant_scene = runtime_matrix_scene((T=12.0, duration=Hour(1)))
    constant_sim = run!(constant_scene; steps=2, outputs=:all)
    @test last.(outputs(constant_sim)[(:probe, ObjectId(:probe), :seen)]) == [12.0, 12.0]

    one_row_scene = runtime_matrix_scene([(T=13.0, duration=Hour(1))])
    one_row_sim = run!(one_row_scene)
    @test only(model_objects(one_row_scene)).status.seen == 13.0
    @test_throws Exception run!(runtime_matrix_scene([(T=13.0, duration=Hour(1))]); steps=2)

    rows = [(T=14.0, duration=Hour(1)), (T=15.0, duration=Hour(1))]
    selected_scene = runtime_matrix_scene(rows)
    selected_sim = run!(
        selected_scene;
        steps=2,
        outputs=OutputRequest(:Leaf, :seen; name=:selected_seen),
    )
    selected = collect_outputs(selected_sim, :selected_seen; sink=nothing)
    canonical = outputs(selected_sim)[(:probe, ObjectId(:probe), :seen)]
    @test getproperty.(selected, :value) == last.(canonical) == [14.0, 15.0]

    no_outputs = run!(
        runtime_matrix_scene(rows);
        steps=2,
        outputs=:none,
    )
    @test isempty(outputs(no_outputs))
    @test isempty(collect_outputs(no_outputs; sink=nothing))

    selector_scene = CompositeModel(
        Object(:sun_leaf; scale=:Leaf, kind=:sun),
        Object(:shade_leaf; scale=:Leaf, kind=:shade);
        applications=(
            ModelSpec(RuntimeMatrixProbeModel(); name=:probe) |>
                AppliesTo(Many(scale=:Leaf)),
        ),
        environment=(T=16.0, duration=Hour(1)),
    )
    selector_sim = run!(
        selector_scene;
        outputs=OutputRequest(
            One(kind=:sun),
            :seen;
            name=:sun_seen,
            application=:probe,
        ),
    )
    selector_rows = collect_outputs(selector_sim, :sun_seen; sink=nothing)
    @test getproperty.(selector_rows, :object_id) == [:sun_leaf]
    @test getproperty.(selector_rows, :value) == [16.0]

    contextual_sim = run!(
        selector_scene;
        outputs=OutputRequest(
            One(Self()),
            :seen;
            name=:self_seen,
            application=:probe,
            context=:shade_leaf,
        ),
    )
    contextual_rows = collect_outputs(contextual_sim, :self_seen; sink=nothing)
    @test getproperty.(contextual_rows, :object_id) == [:shade_leaf]

    continued_scene = runtime_matrix_scene([
        (T=17.0, duration=Hour(1)),
        (T=18.0, duration=Hour(1)),
        (T=19.0, duration=Hour(1)),
    ])
    continued_sim = run!(continued_scene; outputs=:all)
    continue!(continued_sim; steps=2)
    @test last.(outputs(continued_sim)[
        (:probe, ObjectId(:probe), :seen)
    ]) == [17.0, 18.0, 19.0]
end
