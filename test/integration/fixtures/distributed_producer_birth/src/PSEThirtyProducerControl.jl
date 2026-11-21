module PSEThirtyProducerControl
import PlantSimEngine as PSE
include("native_preparation.jl")
using .NativePreparation: close_registry, RuntimeTypes, InputTrace, remember!, batch_schema
include("distributed_growth.jl")
include("prepare.jl")
include("leaf_recovery.jl")
const STATE = prepare_control()
function (@main)(args)
    length(args) == 1 && only(args) == "recover" && return LeafRecovery.qualify()
    isempty(args) || return Cint(2)
    checkpoint(STATE, 0) || return Cint(10)
    sim = STATE.simulation
    root, producer = sim.execution_plan.groups_by_application_slot
    root.application.id === :birth && producer.application.id === :producer || return Cint(30)
    root_batch = only(root.batches)
    isempty(producer.membership.object_ids) && isempty(producer.batches) || return Cint(31)
    for day in 1:3
        PSE.step!(STATE.simulation)
        checkpoint(STATE, day) || return Cint(10 + day)
        if day == 2
            changed = sim.compiled.changed_execution_application_ids
            length(changed) == 1 && :producer in changed || return Cint(32)
            current_root, current_producer = sim.execution_plan.groups_by_application_slot
            current_root === root && only(current_root.batches) === root_batch || return Cint(33)
            current_root.application === sim.compiled.applications_by_id[:birth] || return Cint(34)
            current_producer.application === sim.compiled.applications_by_id[:producer] || return Cint(35)
            only(current_producer.membership.object_ids) === PSE.ObjectId(:emitter) || return Cint(36)
            length(current_producer.batches) == 1 || return Cint(37)
        end
    end
    return Cint(0)
end
end
