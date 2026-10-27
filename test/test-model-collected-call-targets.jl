module CollectedCallTargetChecks

using Dates
using PlantSimEngine
using Test

const PSE = PlantSimEngine

PSE.@process "collected_target_owner_probe" verbose=false
PSE.@process "collected_target_leaf_probe" verbose=false

struct CollectionOwner{C} <: AbstractCollected_Target_Owner_ProbeModel
    capture::C
    collect_children::Bool
end
PSE.inputs_(::CollectionOwner) = NamedTuple()
PSE.outputs_(::CollectionOwner) = (visits=0,)
PSE.environment_inputs_(::CollectionOwner) = NamedTuple()
function PSE.run!(model::CollectionOwner, status, environment, constants, context)
    model.capture[] = model.collect_children ? collect(call_targets(context, :leaves)) : context
    status.visits += 1
    return nothing
end

struct CollectedLeaf <: AbstractCollected_Target_Leaf_ProbeModel end
struct AlternateCollectedLeaf <: AbstractCollected_Target_Leaf_ProbeModel end
PSE.inputs_(::AbstractCollected_Target_Leaf_ProbeModel) = (
    driver=Default(0.0), coefficients=Default([1.0, 2.0]),
)
PSE.outputs_(::CollectedLeaf) = (seen=0.0,)
PSE.outputs_(::AlternateCollectedLeaf) = (seen=0.0, alternate=true)
PSE.environment_inputs_(::AbstractCollected_Target_Leaf_ProbeModel) = (T=0.0,)
function PSE.run!(::CollectedLeaf, status, environment, constants, context)
    status.seen = status.driver + sum(status.coefficients) + environment.T
    return nothing
end
function PSE.run!(::AlternateCollectedLeaf, status, environment, constants, context)
    status.seen = status.driver + sum(status.coefficients) + environment.T + 5
    return nothing
end

function collection_scene(::Type{S}; heterogeneous=false) where {S}
    context_capture, child_capture = Ref{Any}(), Ref{Any}()
    leaf_applications = heterogeneous ? (
        ModelSpec(CollectedLeaf(); name=:leaf_a, on=One(id=:leaf_a)),
        ModelSpec(AlternateCollectedLeaf(); name=:leaf_b, on=One(id=:leaf_b)),
    ) : (
        ModelSpec(CollectedLeaf(); name=:leaves, on=Many(scale=:Leaf)),
    )
    leaf_application = heterogeneous ? :leaf_a : :leaves
    model = CompositeModel(
        Object(:owner; scale=:Scene),
        Object(:middle; scale=:Plant, parent=:owner),
        Object(:leaf_a; scale=:Leaf, parent=:middle),
        Object(:leaf_b; scale=:Leaf, parent=:middle);
        applications=(
            ModelSpec(CollectionOwner(context_capture, false); name=:owner, on=One(id=:owner),
                calls=(
                    leaves=Many(scale=:Leaf, within=SceneScope(), process=:collected_target_leaf_probe),
                    empty=Many(id=:missing, within=SceneScope(), process=:collected_target_leaf_probe),
                    optional_empty=OptionalOne(id=:missing, within=SceneScope(), application=leaf_application),
                    middle=One(id=:middle, within=SceneScope(), application=:middle),
                )),
            ModelSpec(CollectionOwner(child_capture, true); name=:middle, on=One(id=:middle),
                calls=(leaves=One(id=:leaf_a, within=SceneScope(), application=leaf_application),)),
            leaf_applications...,
        ),
        environment=[
            (date=DateTime(2026, 1, 1), duration=Hour(1), T=20.0),
            (date=DateTime(2026, 1, 1, 1), duration=Hour(1), T=30.0),
        ],
        type_promotion=Dict(Float64 => S),
    )
    return (; model, context_capture, child_capture)
end

function leaf_rows(simulation)
    rows = collect_outputs(simulation, :leaf_a, :seen; sink=nothing)
    return sort!(rows; by=row -> row.timestep)
end

@testset "collected hard-call targets preserve types, order and live storage" begin
    for S in (Float32, Float64), heterogeneous in (false, true)
        @testset "storage=$S heterogeneous=$heterogeneous" begin
            scene = collection_scene(S; heterogeneous)
            simulation = run!(scene.model; steps=1, outputs=:all)
            targets = call_targets(scene.context_capture[], :leaves)
            collected = collect(targets)
            @test collected isa Vector{<:CallTarget}
            widened = collect(CallTarget, targets)
            @test widened isa Vector{CallTarget}
            @test getproperty.(widened, :object_id) == getproperty.(collected, :object_id)
            @test length(targets) == length(collected) == 2
            @test getproperty.(collected, :object_id) == ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)]
            if heterogeneous
                @test collected[1].model isa CollectedLeaf
                @test collected[2].model isa AlternateCollectedLeaf
                @test typeof(collected[1].status) !== typeof(collected[2].status)
                @test collected[2].status.alternate
            else
                @test isconcretetype(eltype(collected))
                @test typeof(collected[1]) === typeof(collected[2]) === eltype(collected)
            end

            another = collect(targets)
            @test another !== collected
            for index in eachindex(collected)
                @test targets[index].object_id == collected[index].object_id
                @test targets[index].model === collected[index].model
                @test targets[index].status === collected[index].status === another[index].status
                @test collected[index].status.seen isa S
                @test collected[index].status.driver isa S
            end
            for index in (-1, 0, 3)
                @test_throws BoundsError targets[index]
            end

            first = collected[1]
            first.status.driver = 2.5
            @test first.status.driver === S(2.5)
            @test model_status(scene.model, :leaf_a).driver === S(2.5)
            coefficients = first.status.coefficients
            @test another[1].status.coefficients === coefficients
            coefficients[1] = 4
            @test model_status(scene.model, :leaf_a).coefficients === coefficients
            @test run_call!(first; publish=false) === first
            @test first.status.seen === S(28.5)
            @test isempty(leaf_rows(simulation))

            pop!(another)
            @test length(another) == 1
            @test length(collected) == length(targets) == length(collect(targets)) == 2
            for name in (:empty, :optional_empty)
                empty_targets = call_targets(scene.context_capture[], name)
                empty = collect(empty_targets)
                @test empty isa Vector{CallTarget}
                @test isempty(empty)
                @test_throws BoundsError empty_targets[1]
            end
        end
    end
end

@testset "collected snapshots retain caller metadata while sharing live references" begin
    for S in (Float32, Float64)
        scene = collection_scene(S)
        simulation = run!(scene.model; steps=1, outputs=:all)
        old = collect(call_targets(scene.context_capture[], :leaves))
        middle = only(call_targets(scene.context_capture[], :middle))
        rejected_environment = (T=50.0, duration=Hour(1))
        accepted_environment = (T=70.0, duration=Hour(1))
        run_call!(middle; environment=rejected_environment, publish=false)
        rejected = scene.child_capture[]
        @test !only(rejected).publication_allowed
        @test only(rejected).environment === rejected_environment
        run_call!(middle; environment=accepted_environment, publish=true)
        accepted = scene.child_capture[]
        @test accepted !== rejected
        @test only(accepted).publication_allowed
        @test only(accepted).environment === accepted_environment
        @test only(rejected).environment === rejected_environment
        @test !only(rejected).publication_allowed

        run_call!(only(rejected); publish=true)
        @test old[1].status.seen === S(53)
        @test isempty(leaf_rows(simulation))
        run_call!(only(accepted); publish=true)
        @test only(leaf_rows(simulation)).value === S(73)

        step!(simulation)
        current = collect(call_targets(scene.context_capture[], :leaves))
        @test current !== old
        @test old[1].time == 1 && current[1].time == 2
        @test old[1].status === current[1].status
        current[1].status.driver = 7.5
        @test old[1].status.driver === S(7.5)
        run_call!(current[1]; publish=true)
        @test current[1].status.seen === S(40.5)
        run_call!(old[1]; publish=true)
        @test old[1].status.seen === S(30.5)
        rows = leaf_rows(simulation)
        @test getproperty.(rows, :timestep) == [1, 2]
        @test getproperty.(rows, :value) == S[30.5, 40.5]
        @test only(rejected).time == 1
        @test only(rejected).environment === rejected_environment
        @test !only(rejected).publication_allowed
    end
end

@testset "collecting a retained Many refreshes membership after lifecycle changes" begin
    scene = collection_scene(Float64)
    simulation = run!(scene.model; steps=1, outputs=:none)
    targets = call_targets(scene.context_capture[], :leaves)
    before = collect(targets)
    register_object!(scene.model, Object(:leaf_c; scale=:Leaf, parent=:middle))
    step!(simulation)
    after = collect(targets)
    @test length(before) == 2
    @test getproperty.(after, :object_id) ==
        ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b), ObjectId(:leaf_c)]
    @test isconcretetype(eltype(after))
    @test targets[3].object_id == ObjectId(:leaf_c)
    @test_throws BoundsError targets[4]
end

@testset "collecting an empty retained Many observes a newly matching object" begin
    scene = collection_scene(Float64)
    simulation = run!(scene.model; steps=1, outputs=:none)
    targets = call_targets(scene.context_capture[], :empty)
    before = collect(targets)
    @test before isa Vector{CallTarget}
    @test isempty(before)
    register_object!(scene.model, Object(:missing; scale=:Leaf, parent=:middle))
    step!(simulation)
    after = collect(targets)
    @test isempty(before)
    @test length(after) == 1
    @test isconcretetype(eltype(after))
    @test only(after).object_id == ObjectId(:missing)
    @test targets[1].status === only(after).status
end

end # module CollectedCallTargetChecks
