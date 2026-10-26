module OnlyCallTargetChecks

using Dates
using PlantSimEngine
using Test

const PSE = PlantSimEngine

PSE.@process "only_target_owner_probe" verbose=false
PSE.@process "only_target_leaf_probe" verbose=false

struct OnlyOwner{C} <: AbstractOnly_Target_Owner_ProbeModel
    capture::C
end
PSE.inputs_(::OnlyOwner) = NamedTuple()
PSE.outputs_(::OnlyOwner) = (visits=0,)
PSE.environment_inputs_(::OnlyOwner) = NamedTuple()
PSE.environment_outputs_(::OnlyOwner) = NamedTuple()
function PSE.run!(model::OnlyOwner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end

struct OnlyLeaf <: AbstractOnly_Target_Leaf_ProbeModel end
PSE.inputs_(::OnlyLeaf) = (called_input=Default(0.0),)
PSE.outputs_(::OnlyLeaf) = (leaf_seen=0.0,)
PSE.environment_inputs_(::OnlyLeaf) = (T=0.0,)
PSE.environment_outputs_(::OnlyLeaf) = NamedTuple()
function PSE.run!(::OnlyLeaf, status, environment, constants, context)
    status.leaf_seen = status.called_input + environment.T
    return nothing
end

struct AlternateOnlyLeaf{T} <: AbstractOnly_Target_Leaf_ProbeModel
    offset::T
end
PSE.inputs_(::AlternateOnlyLeaf) = (called_input=Default(0.0),)
PSE.outputs_(::AlternateOnlyLeaf) = (leaf_seen=0.0,)
PSE.environment_inputs_(::AlternateOnlyLeaf) = (T=0.0,)
PSE.environment_outputs_(::AlternateOnlyLeaf) = NamedTuple()
function PSE.run!(model::AlternateOnlyLeaf, status, environment, constants, context)
    status.leaf_seen = status.called_input + environment.T + model.offset
    return nothing
end

function only_scene(::Type{S}; heterogeneous::Bool) where {S}
    capture = Ref{Any}()
    leaf_applications = if heterogeneous
        (
            ModelSpec(OnlyLeaf(); name=:only_leaf_a, on=One(id=:only_a)),
            ModelSpec(AlternateOnlyLeaf(S(3)); name=:only_leaf_b, on=One(id=:only_b)),
        )
    else
        (ModelSpec(OnlyLeaf(); name=:only_leaves, on=Many(scale=:Leaf)),)
    end
    single_application = heterogeneous ? :only_leaf_a : :only_leaves
    model = CompositeModel(
        Object(:only_owner; scale=:Scene),
        Object(:only_a; scale=:Leaf, parent=:only_owner),
        Object(:only_b; scale=:Leaf, parent=:only_owner);
        applications=(
            ModelSpec(OnlyOwner(capture); name=:only_owner, on=One(id=:only_owner), calls=(
                single=One(id=:only_a, within=SceneScope(), application=single_application),
                optional_present=OptionalOne(id=:only_a, within=SceneScope(), application=single_application),
                optional_absent=OptionalOne(id=:missing, within=SceneScope(), application=single_application),
                many_single=Many(id=:only_a, within=SceneScope(), process=:only_target_leaf_probe),
                many_empty=Many(id=:missing, within=SceneScope(), process=:only_target_leaf_probe),
                many_multiple=Many(scale=:Leaf, within=SceneScope(), process=:only_target_leaf_probe),
            )),
            leaf_applications...,
        ),
        environment=[
            (date=DateTime(2026, 1, 1), duration=Hour(1), T=20.0),
            (date=DateTime(2026, 1, 1, 1), duration=Hour(1), T=30.0),
        ],
        type_promotion=Dict(Float64 => S),
    )
    return (; model, capture)
end

function only_error(collection)
    try
        only(collection)
    catch error
        return error
    end
    return nothing
end

@testset "only(CallTargets) preserves singular snapshots and collection errors" begin
    for S in (Float32, Float64), heterogeneous in (false, true)
        @testset "storage=$S heterogeneous=$heterogeneous" begin
            scene = only_scene(S; heterogeneous)
            simulation = run!(scene.model; steps=1, outputs=:all)
            context = scene.capture[]

            for name in (:single, :optional_present, :many_single)
                targets = call_targets(context, name)
                view = only(targets)
                indexed = targets[1]
                iterated, _ = iterate(targets)
                @test view isa PSE.CallTarget
                @test view.object_id == ObjectId(:only_a)
                @test view.model === indexed.model === iterated.model
                @test view.status === indexed.status === iterated.status
                @test view.canonical_status === indexed.canonical_status === iterated.canonical_status
                @test view.time === indexed.time === iterated.time
                @test view.environment === indexed.environment === iterated.environment
                @test view.publication_allowed === indexed.publication_allowed === iterated.publication_allowed
                @test view.calls === indexed.calls === iterated.calls
            end

            for name in (:optional_absent, :many_empty, :many_multiple)
                targets = call_targets(context, name)
                # A generator keeps this comparison on Base's generic iterator
                # implementation rather than invoking the specialized method.
                generic_error = only_error((target for target in targets))
                specialized_error = only_error(targets)
                @test generic_error isa ArgumentError
                @test specialized_error isa ArgumentError
                @test sprint(showerror, specialized_error) == sprint(showerror, generic_error)
            end

            first = only(call_targets(context, :single))
            first.status.called_input = S(7)
            @test isempty(collect_outputs(simulation, :only_a, :leaf_seen; sink=nothing))
            @test run_call!(first; publish=false) === first
            @test first.status.leaf_seen === S(27)
            @test isempty(collect_outputs(simulation, :only_a, :leaf_seen; sink=nothing))
            @test run_call!(first; publish=true) === first
            rows = collect_outputs(simulation, :only_a, :leaf_seen; sink=nothing)
            @test length(rows) == 1
            @test only(rows).value === S(27)

            step!(simulation)
            current = only(call_targets(scene.capture[], :single))
            @test current.status === first.status
            @test current.time != first.time
            run_call!(current; publish=true)
            @test current.status.leaf_seen === S(37)
            # The previous view keeps its original environment and timestamp,
            # even after the same compiled owner is materialized again.
            run_call!(first; publish=true)
            @test first.status.leaf_seen === S(27)
            rows = sort!(collect_outputs(simulation, :only_a, :leaf_seen; sink=nothing); by=row -> row.timestep)
            @test getproperty.(rows, :timestep) == [1, 2]
            @test getproperty.(rows, :value) == S[27, 37]
        end
    end
end

end # module OnlyCallTargetChecks
