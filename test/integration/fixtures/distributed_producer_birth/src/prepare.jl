# Host preparation only: one public scenario, actual finite core owners.
const APPLICATION_IDS = (:birth, :producer)
function state_for(simulation)
    ids = DistributedGrowthFixture.producer_birth_leaf_ids()
    S = typeof(PSE.model_status(simulation, first(ids)))
    leaves = S[PSE.model_status(simulation, id)::S for id in ids]
    ordinals = Base.RefValue{Int}[PSE.refvalue(status, :ordinal) for status in leaves]
    objects = PSE.Object[PSE.model_object(simulation, id) for id in ids]
    listed_objects = objects[sortperm(ids; by=id -> string(id.value))]
    return (; simulation, ids, leaves, ordinals, objects, listed_objects,
        signals=Base.RefValue{Float32}[], streams=Vector{Tuple{Float64,Float32}}[])
end

# Individual public observations, not an aggregate or a second execution path.
function checkpoint(state, day)
    sim, model = state.simulation, state.simulation.model
    PSE.current_step(sim) == day || return false
    length(state.ids) == 30 || return false
    listed = PSE.model_objects(model; scale=:Leaf)
    length(listed) == 30 || return false
    all(i -> listed[i] === state.listed_objects[i], eachindex(listed)) || return false
    length(model.registry.objects) == 31 + Int(day >= 2) || return false
    haskey(model.registry.objects, PSE.ObjectId(:emitter)) == (day >= 2) || return false
    for index in eachindex(state.ids)
        id, status = state.ids[index], state.leaves[index]
        object = PSE.model_object(model, id)
        object === state.objects[index] && object.scale === :Leaf || return false
        PSE.refvalue(status, :ordinal) === state.ordinals[index] || return false
        status.ordinal == index || return false
        snapshot = PSE.final_state(sim, id)
        snapshot isa NamedTuple && isdefined(snapshot, :ordinal) || return false
        getfield(snapshot, :ordinal) === index || return false
        reference = PSE._initial_status_reference(status, :signal)
        stream = get(PSE.outputs(sim), (:producer, id, :signal), nothing)
        if day < 2
            isdefined(snapshot, :signal) && return false
            isnothing(reference) || return false
            (isnothing(stream) || (stream isa Vector{Tuple{Float64,Float32}} && isempty(stream))) || return false
        else
            isdefined(snapshot, :signal) && getfield(snapshot, :signal) === Float32(20day) || return false
            reference isa Base.RefValue{Float32} || return false
            reference[] === Float32(20day) || return false
            stream isa Vector{Tuple{Float64,Float32}} || return false
            stream = stream::Vector{Tuple{Float64,Float32}}
            length(stream) == day - 1 || return false
            for sample in eachindex(stream)
                stream[sample] === (Float64(sample + 1), Float32(20(sample + 1))) || return false
            end
            if day == 2
                push!(state.signals, reference)
                push!(state.streams, stream)
            else
                reference === state.signals[index] || return false
                stream === state.streams[index] || return false
            end
        end
    end
    return true
end

function advance_host!(state; observe=(_ -> nothing))
    checkpoint(state, 0) || error("Thirty initial individual checkpoints changed.")
    observe(state.simulation)
    for day in 1:3
        PSE.step!(state.simulation)
        checkpoint(state, day) || error("Thirty individual values/history changed at step $day.")
        observe(state.simulation)
    end
    return nothing
end

function prepare_control()
    # The public ordinary maintained test is independently executed by the host gate.
    baseline = state_for(PSE.run!(DistributedGrowthFixture.make_producer_birth_model();
        steps=0, outputs=:all))
    advance_host!(baseline)
    observed = RuntimeTypes()
    input_trace = InputTrace(observed)
    environment = PSE._collecting_environment_binding_schema()
    recording = PSE._prepare_simulation!(close_registry(DistributedGrowthFixture.make_producer_birth_model());
        steps=0, outputs=:all, constants=PSE.Constants(), environment_schema=environment,
        input_binding_storage=input_trace, status_view_schema=observed)
    advance_host!(state_for(recording))
    isempty(input_trace) || error("Input prototype was mutated.")
    all(T -> isconcretetype(T) && T <: PSE.CompiledModelInputBinding, observed.inputs) || error("Invalid actual input evidence.")
    prototype = Vector{Union{observed.inputs...}}()
    schema = PSE.CompiledMetadataTable(NamedTuple{APPLICATION_IDS}(map(APPLICATION_IDS) do id
        types = observed.views[id]
        all(T -> isconcretetype(T) && T <: PSE.CompiledModelStatusView, types) || error("Invalid actual view evidence.")
        Vector{Union{types...}}()
    end))
    environment = PSE._freeze_environment_binding_schema(environment)
    prepare() = PSE._prepare_simulation!(close_registry(DistributedGrowthFixture.make_producer_birth_model());
        steps=0, outputs=:all, constants=PSE.Constants(), environment_schema=environment,
        input_binding_storage=prototype, status_view_schema=schema)
    finite = prepare()
    batches = Dict(id => DataType[] for id in APPLICATION_IDS)
    function observe_batches(sim)
        sim.compiled.input_bindings isa Vector{eltype(prototype)} || error("Lost finite input owner.")
        sim.compiled.status_view_schema === schema || error("Lost finite view owner.")
        for group in sim.execution_plan.groups, batch in group.batches
            types = batches[batch.application.id]
            remember!(types, typeof(batch))
        end
    end
    advance_host!(state_for(finite); observe=observe_batches)
    schemas = NamedTuple{APPLICATION_IDS}(map(id -> batch_schema(batches[id]), APPLICATION_IDS))
    simulation = PSE._prepare_execution_batch_schemas(prepare(), schemas)
    state = state_for(simulation)
    checkpoint(state, 0) || error("Final native scene was advanced or changed.")
    return state
end
