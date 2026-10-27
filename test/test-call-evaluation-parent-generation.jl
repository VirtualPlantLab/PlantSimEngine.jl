module CallEvaluationParentGenerationChecks

using Dates, PlantSimEngine, Test

const PSE = PlantSimEngine

PSE.@process "evaluation_generation_owner_probe" verbose=false
PSE.@process "evaluation_generation_parent_probe" verbose=false
PSE.@process "evaluation_generation_child_probe" verbose=false

struct GenerationOwner{C} <: AbstractEvaluation_Generation_Owner_ProbeModel
    capture::C
end
PSE.outputs_(::GenerationOwner) = (visits=0,)
function PSE.run!(model::GenerationOwner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end

struct GenerationChild <: AbstractEvaluation_Generation_Child_ProbeModel end
PSE.outputs_(::GenerationChild) = (calls=0, seen=0.0)
PSE.environment_inputs_(::GenerationChild) = (T=0.0,)
function PSE.run!(::GenerationChild, status, environment, constants, context)
    status.calls += 1
    status.seen = environment.T
    return nothing
end

struct GenerationParent{C} <: AbstractEvaluation_Generation_Parent_ProbeModel
    child_evaluation::C
end
PSE.inputs_(::GenerationParent) = (mode=Default(:capture),)
PSE.outputs_(::GenerationParent) = (visits=0,)
function PSE.run!(model::GenerationParent, status, environment, constants, context)
    status.visits += 1
    if status.mode === :capture || status.mode === :capture_and_accept
        evaluated = evaluate_call!(context, :child; sampled_environment=(T=31.0,))
        model.child_evaluation[] = evaluated
        status.mode === :capture_and_accept && accept_call!(evaluated)
    elseif status.mode === :accept_saved
        accept_call!(model.child_evaluation[])
    else
        error("Unknown generation-test mode")
    end
    return nothing
end

function generation_scene(; empty_child=false)
    capture = Ref{Any}()
    child_evaluation = Ref{Any}()
    child = empty_child ?
        Many(id=:absent, within=Subtree(), application=:child) :
        One(id=:child, within=Subtree(), application=:child)
    model = CompositeModel(
        Object(:owner; scale=:Scene),
        Object(:parent; scale=:Plant, parent=:owner),
        Object(:child; scale=:Leaf, parent=:parent);
        applications=(
            ModelSpec(GenerationOwner(capture); name=:owner, on=One(id=:owner),
                calls=(
                    parent=One(id=:parent, within=Subtree(), application=:parent),
                    # Keep the leaf application manually owned even when the
                    # tested parent selection is empty. This declaration is not
                    # executed by the context-capture owner.
                    child_anchor=One(id=:child, within=Subtree(), application=:child),
                )),
            ModelSpec(GenerationParent(child_evaluation); name=:parent, on=One(id=:parent),
                calls=(child=child,)),
            ModelSpec(GenerationChild(); name=:child, on=One(id=:child)),
        ), environment=(T=10.0, duration=Hour(1)))
    simulation = run!(model; steps=1, outputs=:all)
    return (; model, simulation, capture, child_evaluation)
end

@testset "A reused parent workspace cannot adopt a previous generation's child token" begin
    for empty_child in (false, true)
        fixture = generation_scene(; empty_child)
        context = fixture.capture[]
        previous_parent = evaluate_call!(context, :parent)
        child = fixture.child_evaluation[]
        @test isempty(call_targets(child)) == empty_child
        @test isempty(outputs(fixture.simulation)[(:child, ObjectId(:child), :seen)])
        model_status(fixture.model, :parent).mode = :accept_saved
        # The parent selection and workspace are identical, and no child target
        # is reexecuted in this second parent candidate. Parent generation,
        # rather than child execution or topology revision, must reject it.
        @test_throws ArgumentError evaluate_call!(context, :parent)
        @test_throws ArgumentError accept_call!(previous_parent)
        @test isempty(outputs(fixture.simulation)[(:child, ObjectId(:child), :seen)])
        @test model_status(fixture.model, :child).calls == (empty_child ? 0 : 1)
    end
end

@testset "A nested token can be accepted inside its original parent generation" begin
    fixture = generation_scene()
    model_status(fixture.model, :parent).mode = :capture_and_accept
    evaluated = evaluate_call!(fixture.capture[], :parent)
    @test model_status(fixture.model, :child).calls == 1
    @test isempty(outputs(fixture.simulation)[(:child, ObjectId(:child), :seen)])
    accept_call!(evaluated)
    @test model_status(fixture.model, :child).calls == 1
    @test outputs(fixture.simulation)[(:child, ObjectId(:child), :seen)] == [(1.0, 31.0)]
end


@testset "Unaccepted nested child execution still invalidates the parent candidate" begin
    fixture = generation_scene()
    pending_parent = evaluate_call!(fixture.capture[], :parent)
    child = only(call_targets(fixture.child_evaluation[]))
    @test child.status.seen == 31.0
    run_call!(child; sampled_environment=(T=90.0,), publish=false)
    @test child.status.calls == 2
    @test_throws ArgumentError accept_call!(pending_parent)
    @test isempty(outputs(fixture.simulation)[(:parent, ObjectId(:parent), :visits)])
    @test isempty(outputs(fixture.simulation)[(:child, ObjectId(:child), :seen)])
end

struct SuppressedEvaluationMiddle{C} <: AbstractEvaluation_Generation_Parent_ProbeModel
    child_evaluation::C
end
PSE.outputs_(::SuppressedEvaluationMiddle) = (observed=0.0,)
function PSE.run!(model::SuppressedEvaluationMiddle, status, environment, constants, context)
    evaluated = evaluate_call!(context, :child; sampled_environment=(T=31.0,))
    model.child_evaluation[] = evaluated
    accept_call!(evaluated)
    status.observed = only(call_targets(evaluated)).status.seen
    return nothing
end
struct SuppressedEvaluationParent <: AbstractEvaluation_Generation_Parent_ProbeModel end
PSE.outputs_(::SuppressedEvaluationParent) = (observed=0.0,)
function PSE.run!(::SuppressedEvaluationParent, status, environment, constants, context)
    middle = only(run_call!(context, :middle; publish=false))
    status.observed = middle.status.observed
    return nothing
end

function suppressed_generation_scene()
    capture = Ref{Any}()
    child_evaluation = Ref{Any}()
    model = CompositeModel(Object(:owner; scale=:Scene),
        Object(:parent; scale=:Plant, parent=:owner),
        Object(:middle; scale=:Branch, parent=:parent),
        Object(:child; scale=:Leaf, parent=:middle);
        applications=(
            ModelSpec(GenerationOwner(capture); name=:owner, on=One(id=:owner),
                calls=(parent=One(id=:parent, within=Subtree(), application=:parent),)),
            ModelSpec(SuppressedEvaluationParent(); name=:parent, on=One(id=:parent),
                calls=(middle=One(id=:middle, within=Subtree(), application=:middle),)),
            ModelSpec(SuppressedEvaluationMiddle(child_evaluation); name=:middle, on=One(id=:middle),
                calls=(child=One(id=:child, within=Subtree(), application=:child),)),
            ModelSpec(GenerationChild(); name=:child, on=One(id=:child)),
        ), environment=(T=10.0, duration=Hour(1)))
    simulation = run!(model; steps=1, outputs=:all)
    return (; model, simulation, capture, child_evaluation)
end

@testset "Suppressed nested acceptance tracks execution but publishes no child" begin
    for execute_again in (false, true)
        fixture = suppressed_generation_scene()
        pending_parent = evaluate_call!(fixture.capture[], :parent)
        child = only(call_targets(fixture.child_evaluation[]))
        @test child.status.seen == 31.0
        @test child.status.calls == 1
        @test isempty(outputs(fixture.simulation)[(:parent, ObjectId(:parent), :observed)])
        if execute_again
            run_call!(child; sampled_environment=(T=90.0,), publish=false)
            @test_throws ArgumentError accept_call!(pending_parent)
            @test isempty(outputs(fixture.simulation)[(:parent, ObjectId(:parent), :observed)])
        else
            accept_call!(pending_parent)
            @test outputs(fixture.simulation)[(:parent, ObjectId(:parent), :observed)] == [(1.0, 31.0)]
            @test child.status.calls == 1
        end
        @test isempty(outputs(fixture.simulation)[(:middle, ObjectId(:middle), :observed)])
        @test isempty(outputs(fixture.simulation)[(:child, ObjectId(:child), :seen)])
    end
end

struct GrowingEvaluationOwner <: AbstractEvaluation_Generation_Owner_ProbeModel end
PSE.outputs_(::GrowingEvaluationOwner) = (visits=0, accepted_calls=0)
function PSE.run!(::GrowingEvaluationOwner, status, environment, constants, context)
    status.visits += 1
    model = runtime_model(context)
    newborn_id = Symbol("evaluated_newborn_", status.visits)
    register_object!(model, Object(newborn_id; scale=:Leaf, parent=:owner))
    # Resolve the newborn before the scheduled lifecycle barrier. The context
    # may still carry the older compiled scene, while this filtered selection
    # has prepared the new execution target and streams.
    evaluated = evaluate_call!(context, :children; objects=(newborn_id,),
        sampled_environment=(T=10.0 * status.visits,))
    @assert only(call_targets(evaluated)).object_id == ObjectId(newborn_id)
    accept_call!(evaluated)
    status.accepted_calls = only(call_targets(evaluated)).status.calls
    return nothing
end

@testset "Growth before a filtered evaluation preserves immediate accepted publication" begin
    for selection in (:all, :request), initially_empty in (false, true)
        start = DateTime(2026, 10, 27)
        objects = initially_empty ? (Object(:owner; scale=:Scene),) :
            (Object(:owner; scale=:Scene), Object(:existing; scale=:Leaf, parent=:owner))
        model = CompositeModel(objects...;
            applications=(
                ModelSpec(GrowingEvaluationOwner(); name=:owner, on=One(id=:owner),
                    calls=(children=Many(scale=:Leaf, within=Subtree(), application=:child),)),
                ModelSpec(GenerationChild(); name=:child, on=Many(scale=:Leaf)),
            ), environment=[(date=start + Hour(i - 1), T=0.0, duration=Hour(1)) for i in 1:2])
        requested = selection === :all ? :all :
            OutputRequest(Many(scale=:Leaf), :seen; name=:newborn_seen,
                application=:child, policy=HoldLast(), clock=Hour(1))
        simulation = run!(model; steps=1, outputs=requested)
        @test model_status(model, :evaluated_newborn_1).calls == 1
        @test outputs(simulation)[(:child, ObjectId(:evaluated_newborn_1), :seen)] == [(1.0, 10.0)]
        initially_empty || @test model_status(model, :existing).calls == 0
        step!(simulation)
        @test model_status(model, :evaluated_newborn_1).calls == 1
        @test model_status(model, :evaluated_newborn_2).calls == 1
        @test outputs(simulation)[(:child, ObjectId(:evaluated_newborn_2), :seen)] == [(2.0, 20.0)]
        initially_empty || @test model_status(model, :existing).calls == 0
        @test model_status(model, :owner).accepted_calls == 1
        if selection === :request
            rows = collect_outputs(simulation, :newborn_seen; sink=nothing)
            @test any(row -> row.object_id == :evaluated_newborn_1 &&
                row.timestep == 1 && row.value == 10.0, rows)
            @test any(row -> row.object_id == :evaluated_newborn_2 &&
                row.timestep == 2 && row.value == 20.0, rows)
        end
    end
end


struct ReexecutedNewbornOwner <: AbstractEvaluation_Generation_Owner_ProbeModel
    evaluate_first::Bool
end
ReexecutedNewbornOwner() = ReexecutedNewbornOwner(true)
PSE.outputs_(::ReexecutedNewbornOwner) = (reexecution_rejected=false,)
function PSE.run!(controller::ReexecutedNewbornOwner, status, environment, constants, context)
    model = runtime_model(context)
    register_object!(model, Object(:reexecuted_newborn; scale=:Leaf, parent=:owner))
    pending = if controller.evaluate_first
        evaluate_call!(context, :children; objects=(:reexecuted_newborn,),
            sampled_environment=(T=11.0,))
    else
        run_call!(context, :children; objects=(:reexecuted_newborn,),
            sampled_environment=(T=11.0,), publish=false)
        nothing
    end
    # Resolve a second view of the same physical application/object pair. It
    # must share the execution stamp, even before the newborn has an ordinary
    # compiled execution target at the scheduled lifecycle barrier.
    run_call!(context, :children; objects=(:reexecuted_newborn,),
        sampled_environment=(T=91.0,), publish=false)
    if pending !== nothing
        try
            accept_call!(pending)
        catch error
            error isa ArgumentError || rethrow()
            status.reexecution_rejected = occursin("another execution", sprint(showerror, error))
        end
    end
    return nothing
end

# Named output requests include a lifecycle membership's initial live value
# even without a published stream sample. Compare against ordinary unpublished
# calls so these tests verify the new acceptance path adds no publication,
# without changing the pre-existing output projection contract.
function unpublished_newborn_baseline(owner)
    model = CompositeModel(Object(:owner; scale=:Scene); applications=(
        ModelSpec(owner; name=:owner, on=One(id=:owner),
            calls=(children=Many(scale=:Leaf, within=Subtree(), application=:child),)),
        ModelSpec(GenerationChild(); name=:child, on=Many(scale=:Leaf)),
    ), environment=(T=0.0, duration=Hour(1)))
    requested = OutputRequest(Many(scale=:Leaf), :seen; name=:newborn_seen,
        application=:child, policy=HoldLast(), clock=Hour(1))
    simulation = run!(model; steps=1, outputs=requested)
    for id in object_ids(model; scale=:Leaf)
        @test isempty(outputs(simulation)[(:child, id, :seen)])
    end
    return simulation
end

@testset "Reaccessing a targeted newborn invalidates its earlier evaluation" begin
    for selection in (:all, :request)
        model = CompositeModel(Object(:owner; scale=:Scene); applications=(
            ModelSpec(ReexecutedNewbornOwner(); name=:owner, on=One(id=:owner),
                calls=(children=Many(scale=:Leaf, within=Subtree(), application=:child),)),
            ModelSpec(GenerationChild(); name=:child, on=Many(scale=:Leaf)),
        ), environment=(T=0.0, duration=Hour(1)))
        requested = selection === :all ? :all :
            OutputRequest(Many(scale=:Leaf), :seen; name=:newborn_seen,
                application=:child, policy=HoldLast(), clock=Hour(1))
        simulation = run!(model; steps=1, outputs=requested)
        @test model_status(model, :owner).reexecution_rejected
        @test model_status(model, :reexecuted_newborn).calls == 2
        @test model_status(model, :reexecuted_newborn).seen == 91.0
        @test isempty(outputs(simulation)[(:child, ObjectId(:reexecuted_newborn), :seen)])
        if selection === :request
            baseline = unpublished_newborn_baseline(ReexecutedNewbornOwner(false))
            @test model_status(baseline.model, :reexecuted_newborn).calls == 2
            @test isequal(collect_outputs(simulation, :newborn_seen; sink=nothing),
                collect_outputs(baseline, :newborn_seen; sink=nothing))
        end
    end
end


struct MutatedPendingNewbornOwner <: AbstractEvaluation_Generation_Owner_ProbeModel
    evaluate_first::Bool
end
MutatedPendingNewbornOwner() = MutatedPendingNewbornOwner(true)
PSE.outputs_(::MutatedPendingNewbornOwner) = (late_mutation_rejected=false,)
function PSE.run!(controller::MutatedPendingNewbornOwner, status, environment, constants, context)
    model = runtime_model(context)
    register_object!(model, Object(:pending_newborn_a; scale=:Leaf, parent=:owner))
    pending = if controller.evaluate_first
        evaluate_call!(context, :children; objects=(:pending_newborn_a,),
            sampled_environment=(T=11.0,))
    else
        run_call!(context, :children; objects=(:pending_newborn_a,),
            sampled_environment=(T=11.0,), publish=false)
        nothing
    end
    # The first addition already dirtied the scene. Another addition may
    # coalesce into the same model/environment revisions, but it still changes
    # topology after this numerical candidate was evaluated.
    register_object!(model, Object(:pending_newborn_b; scale=:Leaf, parent=:owner))
    if pending !== nothing
        try
            accept_call!(pending)
        catch error
            error isa ArgumentError || rethrow()
            status.late_mutation_rejected = occursin("stale", sprint(showerror, error))
        end
    end
    return nothing
end

@testset "Another addition invalidates evaluation inside an already dirty lifecycle event" begin
    for selection in (:all, :request)
        model = CompositeModel(Object(:owner; scale=:Scene); applications=(
            ModelSpec(MutatedPendingNewbornOwner(); name=:owner, on=One(id=:owner),
                calls=(children=Many(scale=:Leaf, within=Subtree(), application=:child),)),
            ModelSpec(GenerationChild(); name=:child, on=Many(scale=:Leaf)),
        ), environment=(T=0.0, duration=Hour(1)))
        requested = selection === :all ? :all :
            OutputRequest(Many(scale=:Leaf), :seen; name=:newborn_seen,
                application=:child, policy=HoldLast(), clock=Hour(1))
        simulation = run!(model; steps=1, outputs=requested)
        @test model_status(model, :owner).late_mutation_rejected
        @test model_status(model, :pending_newborn_a).calls == 1
        @test model_status(model, :pending_newborn_a).seen == 11.0
        @test model_status(model, :pending_newborn_b).calls == 0
        @test isempty(outputs(simulation)[(:child, ObjectId(:pending_newborn_a), :seen)])
        @test isempty(outputs(simulation)[(:child, ObjectId(:pending_newborn_b), :seen)])
        if selection === :request
            baseline = unpublished_newborn_baseline(MutatedPendingNewbornOwner(false))
            @test model_status(baseline.model, :pending_newborn_a).calls == 1
            @test model_status(baseline.model, :pending_newborn_b).calls == 0
            @test isequal(collect_outputs(simulation, :newborn_seen; sink=nothing),
                collect_outputs(baseline, :newborn_seen; sink=nothing))
        end
    end
end

end # module
