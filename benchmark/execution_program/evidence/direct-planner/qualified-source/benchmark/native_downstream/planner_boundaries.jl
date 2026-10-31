module PlannerBoundaries

using PlantSimEngine
const PSE = PlantSimEngine

for name in (:_ColdPlannerBoundaryPolicy, :_cold_planner_policy,
    :_cold_planner_enter!, :_cold_planner_invoke)
    isdefined(PSE, name) || error("Planner boundaries require the experiment's cold planner hooks")
end

export enable_planner_boundaries!, planner_boundary_report

mutable struct BoundaryState
    enabled::Bool
    policy_selections::Int
    scene_entries::Int
    application_assemblies::Int
    scenario_assemblies::Int
end
BoundaryState() = BoundaryState(false, 0, 0, 0, 0)
const _states = WeakKeyDict{Any,BoundaryState}()

"""Bound inference only in three cold planner phase bodies.

Enable before initial logical preparation. This policy is independent of
BoundedPreparation's metadata containers and any direct execution-plan builder.
The source body, numerical model/status/carrier types and hot batches remain
ordinary. All experiment arms share three cold dynamic dispatch trampolines;
only this opt-in selects the methods with bounded inference.
"""
function enable_planner_boundaries!(model::PSE.CompositeModel)
    state = get!(() -> BoundaryState(), _states, model)
    state.enabled && return model
    isnothing(model.binding_cache) || throw(ArgumentError(
        "Enable planner boundaries before the model's first logical compilation"))
    state.enabled = true
    return model
end

Base.@nospecializeinfer @noinline function PSE._cold_planner_policy(model::PSE.CompositeModel)
    @nospecialize model
    state = get!(() -> BoundaryState(), _states, model)
    state.policy_selections += 1
    return state.enabled ? PSE._ColdPlannerBoundaryPolicy() : Val(:ordinary)
end

Base.@nospecializeinfer @noinline function PSE._cold_planner_enter!(model::PSE.CompositeModel,
    phase::Symbol)
    @nospecialize model
    state = get(_states, model, nothing)
    state !== nothing && state.enabled || error("Unselected cold planner boundary was entered")
    if phase === :_compile_scene_impl
        state.scene_entries += 1
    elseif phase === :_compile_model_applications
        state.application_assemblies += 1
    elseif phase === :_compiled_scenario_plan
        state.scenario_assemblies += 1
    else
        error("Unknown cold planner boundary phase")
    end
    return nothing
end

Base.@nospecializeinfer @noinline function planner_boundary_report(value)
    @nospecialize value
    model = value isa PSE.Simulation ? value.model : value
    model isa PSE.CompositeModel || throw(ArgumentError("Expected CompositeModel or Simulation"))
    state = get(_states, model, nothing)
    return (enabled=state !== nothing && state.enabled,
        policy_selections=state === nothing ? 0 : state.policy_selections,
        shared_cold_dispatches=state === nothing ? 0 : state.policy_selections,
        scene_entries=state === nothing ? 0 : state.scene_entries,
        application_assemblies=state === nothing ? 0 : state.application_assemblies,
        scenario_assemblies=state === nothing ? 0 : state.scenario_assemblies,
        metadata_policy=:independent_of_bounded_containers,
        algorithm_body=:same_shared_source,
        numerical_execution=:unchanged_concrete_models_statuses_carriers_and_batches)
end

end # module
