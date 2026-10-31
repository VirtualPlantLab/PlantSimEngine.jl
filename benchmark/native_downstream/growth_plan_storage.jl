module GrowthPlanStorage

using PlantSimEngine
const PSE = PlantSimEngine

isdefined(PSE, :_compiled_application_plan) || error(
    "Growth plan storage requires the optional application-plan factory hook")

export HeapApplicationPlan, PreboxedApplicationPlan, enable_growth_plan_storage!,
    growth_plan_storage_report

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

"""Share the original boxed cold metadata payloads behind const field bindings.

The six type parameters retain the original argument types as phantom metadata;
the six payload fields store the same supplied values as Any once, instead of
boxing an inline immutable value each time erased code reads it. Model/status/
carrier and numerical execution-batch types are still constructed from their
actual original values by the ordinary compiler. No declaration, model,
selector, environment or scientific reference is copied or sampled here.
"""
mutable struct PreboxedApplicationPlan{S,AT,TM,TS,CL,MO}
    const slot::Int
    const id::Symbol
    const spec::Any
    const process::Symbol
    const name::Union{Nothing,Symbol}
    const applies_to::Any
    const target_matcher::Any
    const timestep::Any
    const clock::Any
    const model_overrides::Any
end

function PreboxedApplicationPlan(slot, id, spec, process, name, applies_to,
    target_matcher, timestep, clock, model_overrides)
    return PreboxedApplicationPlan{typeof(spec),typeof(applies_to),typeof(target_matcher),
        typeof(timestep),typeof(clock),typeof(model_overrides)}(
        slot, id, spec, process, name, applies_to, target_matcher, timestep, clock,
        model_overrides)
end

mutable struct StorageState
    heap_plans_constructed::Int
end
const _enabled = WeakKeyDict{Any,StorageState}()
const _payload_modes = WeakKeyDict{Any,Symbol}()

"""Select shared const-field heap application plans before initial compilation.

This is independent of bounded metadata containers, cold-planner boundaries,
input partition reuse and any numerical driver. The ordinary control continues
to construct the original CompiledApplicationPlan with exactly the same args.
`payload=:concrete` retains the original field types; `payload=:preboxed` keeps
the six original payload values in Any fields once, with their original types
as phantom parameters. The selected mode is fixed for this model's lifetime.
"""
function enable_growth_plan_storage!(model::PSE.CompositeModel; payload::Symbol=:concrete)
    payload in (:concrete, :preboxed) || throw(ArgumentError(
        "Use payload=:concrete or payload=:preboxed"))
    if haskey(_enabled, model)
        get(_payload_modes, model, :concrete) === payload || throw(ArgumentError(
            "Application-plan payload mode is fixed at first enablement"))
        return model
    end
    isnothing(model.binding_cache) || throw(ArgumentError(
        "Enable growth plan storage before the model's first logical compilation"))
    _enabled[model] = StorageState(0)
    _payload_modes[model] = payload
    return model
end

Base.@nospecializeinfer @noinline function PSE._compiled_application_plan(
    model::PSE.CompositeModel, args...
)
    @nospecialize model args
    state = get(_enabled, model, nothing)
    state === nothing && return PSE.CompiledApplicationPlan(args...)
    plan = get(_payload_modes, model, :concrete) === :preboxed ?
        PreboxedApplicationPlan(args...) : HeapApplicationPlan(args...)
    state.heap_plans_constructed += 1
    return plan
end

Base.@nospecializeinfer @noinline function growth_plan_storage_report(value)
    @nospecialize value
    model = value isa PSE.Simulation ? value.model : value
    model isa PSE.CompositeModel || throw(ArgumentError("Expected CompositeModel or Simulation"))
    state = get(_enabled, model, nothing)
    payload_mode = state === nothing ? :ordinary : get(_payload_modes, model, :concrete)
    application_count = nothing
    current_heap_plans = nothing
    current_concrete_heap_plans = nothing
    current_preboxed_plans = nothing
    shell_payload_bytes = nothing
    if value isa PSE.Simulation
        application_count = length(value.compiled.applications)
        current_heap_plans = 0
        current_concrete_heap_plans = 0
        current_preboxed_plans = 0
        shell_payload_bytes = 0
        for application in value.compiled.applications
            plan = getfield(application, :plan)
            current_concrete_heap_plans += plan isa HeapApplicationPlan
            current_preboxed_plans += plan isa PreboxedApplicationPlan
            current_heap_plans += plan isa Union{HeapApplicationPlan,PreboxedApplicationPlan}
            shell_payload_bytes += sizeof(application)
        end
    end
    return (enabled=state !== nothing, payload_mode,
        heap_plans_constructed=state === nothing ? 0 : state.heap_plans_constructed,
        concrete_plans_constructed=payload_mode === :concrete ? state.heap_plans_constructed : 0,
        preboxed_plans_constructed=payload_mode === :preboxed ? state.heap_plans_constructed : 0,
        current_applications=application_count, current_heap_plans,
        current_concrete_heap_plans, current_preboxed_plans,
        application_shell_payload_bytes=shell_payload_bytes,
        plan_fields_read_only=all(type -> all(name -> isconst(Base.unwrap_unionall(type), name),
            fieldnames(Base.unwrap_unionall(type))), (HeapApplicationPlan,PreboxedApplicationPlan)),
        constructor_counter_scope=:enabled_candidate_factory_calls_only,
        retained_metadata=:same_original_constructor_arguments_once_per_plan,
        payload_storage=payload_mode === :preboxed ? :boxed_cold_payload_values : :concrete_fields,
        scientific_storage=:unchanged,
        interpretation=:shared_plan_identity_not_status_or_binding_value_reuse)
end

end # module
