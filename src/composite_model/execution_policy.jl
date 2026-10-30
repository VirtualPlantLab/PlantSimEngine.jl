# Internal experimental lowering controls. These are compiler strategies for
# the same model/object feature contract, not parallel public configuration APIs.
struct _ExecutionPolicy
    narrow_status::Bool
    local_context::Bool
    shared_plans::Bool
end

const _DEFAULT_EXECUTION_POLICY = _ExecutionPolicy(false, false, false)
const _EXECUTION_POLICY_TLS_KEY = :PlantSimEngine_execution_policy

_execution_policy() = get(
    task_local_storage(), _EXECUTION_POLICY_TLS_KEY, _DEFAULT_EXECUTION_POLICY,
)::_ExecutionPolicy

function _with_execution_policy(
    f::F; narrow_status::Bool=false, local_context::Bool=false,
    shared_plans::Bool=false,
) where {F}
    policy = _ExecutionPolicy(narrow_status, local_context, shared_plans)
    return task_local_storage(f, _EXECUTION_POLICY_TLS_KEY, policy)
end

function _execution_policy_for_model(model)
    previous = model.binding_cache
    return previous isa CompiledCompositeModel ? previous.execution_policy :
           _execution_policy()
end
