module RuntimeSnapshotIsolationChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine
PSE.@process "runtime_snapshot_isolation" verbose=false

struct Probe{C,H} <: AbstractRuntime_Snapshot_IsolationModel
    hint_calls::C
    empty_hint::H
end
PSE.inputs_(::Probe) = NamedTuple()
PSE.outputs_(::Probe) = (visits=0,)
function PSE.environment_hint(model::Probe)
    model.hint_calls[] += 1
    return model.empty_hint[] ? NamedTuple() : nothing
end
function PSE.run!(::Probe, status, environment, constants, context)
    status.visits += 1
    return nothing
end

function fixture()
    hint_calls, empty_hint = Ref(0), Ref(false)
    spec = ModelSpec(Probe(hint_calls, empty_hint); name=:probe, on=Many(scale=:Leaf))
    model = CompositeModel(Object(:root; scale=:Scene),
        Object(:leaf; scale=:Leaf, parent=:root); applications=(spec,))
    simulation = run!(model; steps=1, outputs=:all)
    return (; model, simulation, hint_calls, empty_hint)
end

@testset "adapter snapshots leave current live metadata and structural deltas authoritative" begin
    data = fixture()
    model, simulation = data.model, data.simulation
    compiled = simulation.compiled
    plan = compiled.scenario_plan
    preparation = model.scenario_plan_cache
    original_ref = PSE.refvalue(model_status(model, :leaf), :visits)
    @test data.hint_calls[] == 1

    clean_snapshot = PSE._prepare_scenario_plan(model; force=true)
    @test identity(clean_snapshot.plan !== plan)
    @test identity(clean_snapshot.plan.authoring.preparation === preparation)
    @test identity(model.binding_cache === compiled)
    step!(simulation)
    @test identity(simulation.compiled === compiled)
    @test identity(simulation.compiled.scenario_plan === plan)
    @test model_status(model, :leaf).visits == 2
    @test data.hint_calls[] == 1

    register_object!(model, Object(:born; scale=:Leaf, parent=:root))
    born_snapshot = PSE._prepare_scenario_plan(model; force=true)
    @test identity(born_snapshot.plan !== plan)
    @test ObjectId(:born) in only(PSE._scenario_applications(born_snapshot, eltype(eltype(born_snapshot.target_ids)))).target_ids
    @test identity(model.binding_cache === compiled)
    @test PSE.bindings_dirty(model)
    step!(simulation)
    @test identity(simulation.compiled.scenario_plan === plan)
    @test identity(simulation.compiled.scenario_plan.authoring.preparation === preparation)
    @test identity(PSE.refvalue(model_status(model, :leaf), :visits) === original_ref)
    @test model_status(model, :leaf).visits == 3
    @test model_status(model, :born).visits == 1
    @test data.hint_calls[] == 1

    reparent_object!(model, :born, :leaf)
    reparent_snapshot = PSE._prepare_scenario_plan(model; force=true)
    @test identity(reparent_snapshot.plan !== plan)
    step!(simulation)
    @test identity(simulation.compiled.scenario_plan === plan)
    @test model_status(model, :leaf).visits == 4
    @test model_status(model, :born).visits == 2
    @test data.hint_calls[] == 1

    remove_object!(model, :born)
    removed_snapshot = PSE._prepare_scenario_plan(model; force=true)
    @test only(PSE._scenario_applications(removed_snapshot, eltype(eltype(removed_snapshot.target_ids)))).target_ids == [ObjectId(:leaf)]
    step!(simulation)
    @test identity(simulation.compiled.scenario_plan === plan)
    @test model_status(model, :leaf).visits == 5
    @test data.hint_calls[] == 1
    @test collect(outputs(simulation)[(:probe, ObjectId(:born), :visits)]) == [(3.0, 1), (4.0, 2)]
    @test collect(outputs(simulation)[(:probe, ObjectId(:leaf), :visits)]) ==
          [(1.0, 1), (2.0, 2), (3.0, 3), (4.0, 4), (5.0, 5)]

    # Public force really publishes new authored metadata; an adapter snapshot
    # afterward cannot silently replace that CURRENT cache a second time.
    data.empty_hint[] = true
    current = Advanced.refresh_bindings!(model; force=true)
    current_plan = current.scenario_plan
    @test identity(current_plan !== plan)
    @test current isa typeof(compiled)
    @test data.hint_calls[] == 2
    forced_snapshot = PSE._prepare_scenario_plan(model; force=true)
    @test identity(forced_snapshot.plan !== current_plan)
    @test identity(forced_snapshot.plan.authoring.preparation === current_plan.authoring.preparation)
    @test identity(model.binding_cache === current)
    step!(simulation)
    @test identity(simulation.compiled === current)
    @test identity(simulation.compiled.scenario_plan === current_plan)
    @test data.hint_calls[] == 2
    @test model_status(model, :leaf).visits == 6
    @test collect(outputs(simulation)[(:probe, ObjectId(:leaf), :visits)]) ==
          [(1.0, 1), (2.0, 2), (3.0, 3), (4.0, 4), (5.0, 5), (6.0, 6)]
end

PSE.@process "snapshot_selection_child" verbose=false
PSE.@process "snapshot_selection_controller" verbose=false
struct SelectionChild <: AbstractSnapshot_Selection_ChildModel end
PSE.inputs_(::SelectionChild) = NamedTuple()
PSE.outputs_(::SelectionChild) = (value=0, child_calls=0)
function PSE.run!(::SelectionChild, status, environment, constants, context)
    status.value += 1
    status.child_calls += 1
    return nothing
end

struct SelectionController{H,F} <: AbstractSnapshot_Selection_ControllerModel
    hint_calls::H
    snapshot_before_selection::F
end
PSE.inputs_(::SelectionController) = NamedTuple()
PSE.outputs_(::SelectionController) = (seen=0, controllers=0,
    kept_current_owner=true, kept_selected_owner=true)
function PSE.dep(::SelectionController)
    return (child=Call(One(Subtree(); scale=:Leaf, application=:child)),)
end
function PSE.environment_hint(model::SelectionController)
    model.hint_calls[] += 1
    return nothing
end
function PSE.run!(model::SelectionController, status, environment, constants, context)
    before = context.compiled
    if model.snapshot_before_selection[]
        PSE._prepare_scenario_plan(runtime_model(context); force=true)
    end
    # This is a real controller invocation and the public explicit-selection
    # accessor. It refreshes even when no topology mutation is pending.
    targets = call_targets(context, :child; objects=ObjectId(:leaf))
    status.kept_current_owner = runtime_model(context).binding_cache === before
    status.kept_selected_owner = targets.compiled === before
    target = only(targets)
    run_call!(target; publish=true)
    status.seen = target.status.value
    status.controllers += 1
    return nothing
end

@testset "clean snapshot inside a real controller does not republish through explicit selection" begin
    hints, take_snapshot = Ref(0), Ref(false)
    model = CompositeModel(Object(:root; scale=:Scene),
        Object(:leaf; scale=:Leaf, parent=:root); applications=(
            ModelSpec(SelectionController(hints, take_snapshot);
                name=:controller, on=One(id=:root)),
            ModelSpec(SelectionChild(); name=:child, on=One(id=:leaf)),
        ))
    simulation = run!(model; outputs=:all)
    current = simulation.compiled
    current_plan = current.scenario_plan
    @test hints[] == 1
    @test model_status(model, :root).kept_current_owner
    @test model_status(model, :root).kept_selected_owner
    take_snapshot[] = true
    step!(simulation)
    @test hints[] == 1
    @test identity(simulation.compiled === current)
    @test identity(simulation.compiled.scenario_plan === current_plan)
    @test identity(model.binding_cache === current)
    @test model_status(model, :root).kept_current_owner
    @test model_status(model, :root).kept_selected_owner
    @test model_status(model, :root).seen == 2
    @test model_status(model, :root).controllers == 2
    @test model_status(model, :leaf).value == 2
    @test model_status(model, :leaf).child_calls == 2
    @test collect(outputs(simulation)[(:child, ObjectId(:leaf), :value)]) == [(1.0, 1), (2.0, 2)]
    @test collect(outputs(simulation)[(:controller, ObjectId(:root), :seen)]) == [(1.0, 1), (2.0, 2)]
end

@testset "explicit public host refresh still installs its prepared snapshot" begin
    data = fixture()
    model, simulation = data.model, data.simulation
    previous = simulation.compiled
    snapshot = PSE._prepare_scenario_plan(model; force=true)
    @test identity(model.binding_cache === previous)
    current = Advanced.refresh_bindings!(model)
    @test identity(current !== previous)
    @test identity(current.scenario_plan === snapshot.plan)
    @test identity(model.binding_cache === current)
    @test data.hint_calls[] == 1
    step!(simulation)
    @test identity(simulation.compiled === current)
    @test model_status(model, :leaf).visits == 2
    @test data.hint_calls[] == 1
    @test collect(outputs(simulation)[(:probe, ObjectId(:leaf), :visits)]) == [(1.0, 1), (2.0, 2)]
end

end
