module PSEThirtyProducerControl
import PlantSimEngine as PSE
include("native_preparation.jl")
using .NativePreparation: prepare_growth_fixture
include("distributed_growth.jl")
include("prepare.jl")
include("leaf_recovery.jl")
function remove_initial_leaves!(sim)
    for id in DistributedGrowthFixture.producer_birth_leaf_ids()
        PSE.remove_object!(sim.model, id)
    end
    return sim
end

function first_leaf!(sim; observe=(_ -> nothing))
    PSE.current_step(sim) == 0 || return Cint(38)
    for _ in 1:2
        PSE.step!(sim)
        observe(sim)
    end
    isempty(only(sim.compiled.distributed_outputs.bindings).destination_ids) || return Cint(39)
    id = PSE.ObjectId((:tree, :leaf, 31))
    PSE.register_object!(sim.model, PSE.Object(id; scale=:Leaf, parent=:root))
    PSE.step!(sim)
    leaf = PSE.model_status(sim, id)
    isnothing(leaf) && return Cint(44)
    group = only(sim.compiled.distributed_outputs.bindings)
    only(group.destination_ids) === id || return Cint(40)
    only(parent(group.columns.signal)) === PSE.refvalue(leaf, :signal) || return Cint(41)
    leaf.signal === 60f0 || return Cint(42)
    history = get(PSE.outputs(sim), (:producer, id, :signal), nothing)
    history isa Vector{Tuple{Float64,Float32}} && length(history) == 1 &&
        only(history) === (3.0, 60f0) || return Cint(43)
    return Cint(0)
end

function advance_first_destination!(sim, observe)
    result = first_leaf!(remove_initial_leaves!(sim); observe)
    iszero(result) || error("First leaf failed at checkpoint $result.")
    observe(sim)
end

const STATE = prepare_control()
const WITHOUT_LEAVES = remove_initial_leaves!(deepcopy(STATE.simulation))

function (@main)(args)
    length(args) == 1 && only(args) == "recover" && return LeafRecovery.qualify()
    length(args) == 1 && only(args) == "first-leaf" && return first_leaf!(WITHOUT_LEAVES)
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
