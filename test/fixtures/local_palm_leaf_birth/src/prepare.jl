module LocalPalmLeafBirthPreparation

import PlantSimEngine as PSE
using ..LocalPalmLeafBirth
using ..NativePreparation: close_registry, RuntimeTypes, InputTrace, remember!, batch_schema

const APPLICATION_IDS = (:palm_supply, :leaf_assimilation, :palm_carbon)

# Preparation alone closes the actual registry's ID family. All canonical
# objects, status owners, references, and authored applications are retained.
function prepare(scene; environment_schema, input_binding_storage=nothing, status_view_schema=nothing)
    model = close_registry(scene.model)
    simulation = PSE._prepare_simulation!(model; steps=0, outputs=:all,
        constants=PSE.Constants(), environment_schema, input_binding_storage, status_view_schema)
    return (; scene..., model, simulation)
end

# Host observations are outside the runtime payload. They retain each palm and
# leaf value, ordered history, newborn value, and all canonical biological cells.
function snapshot(state)
    return (step=PSE.current_step(state.simulation),
        records=map(record_values,state.records), newborn=leaf_values(state.newborn),
        histories=Dict(key=>deepcopy(collect(stream)) for (key,stream) in pairs(PSE.outputs(state.simulation))))
end
function cells(state)
    result = Any[]
    for record in state.records
        append!(result,values(record.palm))
        for leaf in record.leaf
            append!(result,values(leaf))
        end
    end
    return result
end
function advance_host!(state,neighbours; observe_batch=(state->nothing))
    observe_batch(state)
    state = acquire_neighbours!(state,neighbours)
    observations = [snapshot(state)]
    references = cells(state)
    observe_batch(state)
    for _ in 1:3
        ordinary_step!(state)
        observe_batch(state)
        push!(observations,snapshot(state))
    end
    before = record_values(first(state.records))
    neighbours = map(record_values,state.records[2:end])
    register_leaf!(state)
    refresh_zero!(state)
    observe_batch(state)
    PSE.current_step(state.simulation) == 3 || error("Refresh advanced the timeline.")
    record_values(first(state.records)) == before || error("Birth advanced A's biology.")
    map(record_values,state.records[2:end]) == neighbours || error("Birth changed a neighbour.")
    all(a===b for (a,b) in zip(references,cells(state))) || error("Birth replaced a canonical cell.")
    push!(observations,snapshot(state))
    ordinary_step!(state)
    observe_batch(state)
    push!(observations,snapshot(state))
    return observations
end

"""Prepare the same fresh local-birth scene using only host-observed families.

All training runs execute the original shared register!/refresh/step! actions.
No trajectory that was used to collect schemas becomes the native payload.
"""
function prepare_native_scene()
    # The real 100-neighbour acquisition admits the same families as runtime 0.
    neighbours = 100
    baseline = advance_host!(prepare_scene(make_scene(0)),neighbours)
    observed = RuntimeTypes()
    input_trace = InputTrace(observed)
    collected = PSE._collecting_environment_binding_schema()
    recording = prepare(make_scene(0); environment_schema=collected,
        input_binding_storage=input_trace,status_view_schema=observed)
    advance_host!(recording,neighbours) == baseline || error("Recording changed state/history.")
    isempty(input_trace) || error("Input prototype was mutated.")
    input_prototype = PSE._prepared_input_bindings(
        length(recording.simulation.compiled.scenario_plan.input_plans), observed.inputs)
    views = PSE.CompiledMetadataTable(NamedTuple{APPLICATION_IDS}(map(APPLICATION_IDS) do id
        types = observed.views[id]
        all(V -> isconcretetype(V) && V <: PSE.CompiledModelStatusView,types) || error("Invalid view family.")
        Vector{Union{types...}}()
    end))
    environment_schema = PSE._freeze_environment_binding_schema(collected)
    finite = prepare(make_scene(0);environment_schema,
        input_binding_storage=input_prototype,status_view_schema=views)
    batches = Dict(id=>DataType[] for id in APPLICATION_IDS)
    function observe_batches(state)
        simulation = state.simulation
        simulation.compiled.input_bindings.family_by_slot === input_prototype.family_by_slot ||
            error("Lost input slot admissions.")
        simulation.compiled.status_view_schema === views && all(isempty,values(views)) || error("Lost view admission.")
        simulation.environment_bindings.environment_schema === environment_schema || error("Lost environment admission.")
        isempty(input_prototype) || error("Finite input prototype was mutated.")
        for group in simulation.execution_plan.groups, batch in group.batches
            remember!(batches[batch.application.id],typeof(batch))
        end
        return nothing
    end
    advance_host!(finite,neighbours;observe_batch=observe_batches) == baseline || error("Finite owners changed state/history.")
    schemas = NamedTuple{APPLICATION_IDS}(map(id->batch_schema(batches[id]),APPLICATION_IDS))
    final = prepare(make_scene(0);environment_schema,
        input_binding_storage=input_prototype,status_view_schema=views)
    simulation = PSE._prepare_execution_batch_schemas(final.simulation,schemas)
    state = (; final...,simulation)
    snapshot(state) == snapshot(prepare_scene(make_scene(0))) || error("Final pristine initial state/history changed.")
    length(state.records)==1 && length(collect(PSE.model_objects(state.model)))==4 || error("Native payload must contain A alone.")
    PSE.current_step(simulation) == 0 || error("Preparation advanced the final scene.")
    return state
end

end # module
