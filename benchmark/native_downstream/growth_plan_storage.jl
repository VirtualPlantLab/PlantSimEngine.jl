module GrowthPlanStorage

using PlantSimEngine
const PSE = PlantSimEngine

isdefined(PSE, :_compiled_application_plan) || error(
    "Growth plan storage requires the optional application-plan factory hook")

export HeapApplicationPlan, enable_growth_plan_storage!, growth_plan_storage_report

"""One shared heap identity for read-only application-plan field bindings.

The field names, types and constructor arguments mirror CompiledApplicationPlan.
Every field is const. Nested model/selector/override objects retain their
original semantics; nothing is copied or made more mutable by this wrapper.
Partial CompiledModelApplication shells can share this object rather than
embedding and repeatedly boxing its complete immutable payload.
"""
mutable struct HeapApplicationPlan{S,AT,TM,TS,CL,MO}
    const slot::Int
    const id::Symbol
    const spec::S
    const process::Symbol
    const name::Union{Nothing,Symbol}
    const applies_to::AT
    const target_matcher::TM
    const timestep::TS
    const clock::CL
    const model_overrides::MO
end

mutable struct StorageState
    heap_plans_constructed::Int
end
const _enabled = WeakKeyDict{Any,StorageState}()

"""Select shared const-field heap application plans before initial compilation.

This is independent of bounded metadata containers, cold-planner boundaries,
input partition reuse and any numerical driver. The ordinary control continues
to construct the original CompiledApplicationPlan with exactly the same args.
"""
function enable_growth_plan_storage!(model::PSE.CompositeModel)
    haskey(_enabled, model) && return model
    isnothing(model.binding_cache) || throw(ArgumentError(
        "Enable growth plan storage before the model's first logical compilation"))
    _enabled[model] = StorageState(0)
    return model
end

Base.@nospecializeinfer @noinline function PSE._compiled_application_plan(
    model::PSE.CompositeModel, args...
)
    @nospecialize model args
    state = get(_enabled, model, nothing)
    state === nothing && return PSE.CompiledApplicationPlan(args...)
    plan = HeapApplicationPlan(args...)
    state.heap_plans_constructed += 1
    return plan
end

Base.@nospecializeinfer @noinline function growth_plan_storage_report(value)
    @nospecialize value
    model = value isa PSE.Simulation ? value.model : value
    model isa PSE.CompositeModel || throw(ArgumentError("Expected CompositeModel or Simulation"))
    state = get(_enabled, model, nothing)
    application_count = nothing
    current_heap_plans = nothing
    shell_payload_bytes = nothing
    if value isa PSE.Simulation
        application_count = length(value.compiled.applications)
        current_heap_plans = 0
        shell_payload_bytes = 0
        for application in value.compiled.applications
            current_heap_plans += getfield(application, :plan) isa HeapApplicationPlan
            shell_payload_bytes += sizeof(application)
        end
    end
    return (enabled=state !== nothing,
        heap_plans_constructed=state === nothing ? 0 : state.heap_plans_constructed,
        current_applications=application_count, current_heap_plans,
        application_shell_payload_bytes=shell_payload_bytes,
        plan_fields_read_only=all(name -> isconst(Base.unwrap_unionall(HeapApplicationPlan), name),
            fieldnames(Base.unwrap_unionall(HeapApplicationPlan))),
        constructor_counter_scope=:enabled_candidate_factory_calls_only,
        retained_metadata=:same_original_constructor_arguments_once_per_plan,
        scientific_storage=:unchanged,
        interpretation=:shared_plan_identity_not_status_or_binding_value_reuse)
end

end # module
