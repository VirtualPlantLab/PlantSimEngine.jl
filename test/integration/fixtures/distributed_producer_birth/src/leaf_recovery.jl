module LeafRecovery
import PlantSimEngine as PSE
using PlantSimEngine: Default, bound_input
using ..NativePreparation: close_registry, RuntimeTypes, InputTrace, remember!, batch_schema
include("raw_status_readers.jl")
const IDS = (:tag, :sum)

function scene()
    return PSE.CompositeModel(PSE.Object(1; scale=:Scene),
        PSE.Object(2; scale=:Leaf, parent=1, status=PSE.Status(x=2.0)); applications=(
            PSE.ModelSpec(EmptyModel(); name=:tag, on=PSE.Many(scale=:Leaf)),
            PSE.ModelSpec(AggregateReader(); name=:sum, on=PSE.One(id=1),
                inputs=(values=PSE.Many(scale=:Leaf, within=PSE.SceneScope(), from_status=true, var=:x),)),
        ))
end

function refused(sim)
    try
        PSE.step!(sim)
    catch err
        err isa ErrorException || return false
        message = err.msg
        return message isa String && message == "Input binding `values` on application `sum` for object `1` reads `x` from objects `[2, 3]`, but no source `Status` reference is available."
    end
    return false
end

function exercise!(sim, observe)
    PSE.current_step(sim) == 0 || return 10
    observe(sim)
    PSE.step!(sim)
    observe(sim)
    binding = only(sim.compiled.input_bindings)
    reference = only(parent(binding.carrier))
    history = get(PSE.outputs(sim), (:sum, PSE.ObjectId(1), :total), nothing)
    history isa Vector{Tuple{Float64, Float64}} || return 11
    length(history) == 1 && first(history) === (1.0, 2.0) || return 12
    PSE.register_object!(sim.model, PSE.Object(3; scale=:Leaf, parent=1, status=PSE.Status()))
    for _ in 1:2
        refused(sim) || return 13
        PSE.current_step(sim) == 1 && length(history) == 1 || return 14
        only(sim.compiled.input_bindings) === binding || return 15
        only(parent(binding.carrier)) === reference || return 16
        only(binding.source_ids) === PSE.ObjectId(2) || return 17
        haskey(sim.compiled.applications_by_object, PSE.ObjectId(3)) && return 18
    end
    PSE.remove_object!(sim.model, 3)
    PSE.register_object!(sim.model, PSE.Object(4; scale=:Leaf, parent=1, status=PSE.Status(x=4.0)))
    PSE.step!(sim)
    observe(sim)
    PSE.current_step(sim) == 2 && length(history) == 2 || return 19
    history[1] === (1.0, 2.0) && history[2] === (2.0, 6.0) || return 20
    current = only(sim.compiled.input_bindings)
    length(current.source_ids) == 2 && current.source_ids[1] === PSE.ObjectId(2) &&
        current.source_ids[2] === PSE.ObjectId(4) || return 21
    cells = parent(current.carrier)
    length(cells) == 2 && cells[1] === reference &&
        cells[2] === PSE.refvalue(PSE.model_status(sim, 4), :x) || return 22
    return 0
end

ignore(sim) = nothing

function prepare()
    control = PSE.run!(scene(); steps=0, outputs=:all)
    result = exercise!(control, ignore)
    iszero(result) || error("ordinary retry failed at checkpoint $result")
    observed = RuntimeTypes()
    trace = InputTrace(observed)
    env = PSE._collecting_environment_binding_schema()
    recording = PSE._prepare_simulation!(close_registry(scene()); steps=0, outputs=:all,
        constants=PSE.Constants(), environment_schema=env, input_binding_storage=trace, status_view_schema=observed)
    result = exercise!(recording, ignore)
    iszero(result) || error("recorded retry failed at checkpoint $result")
    inputs = Vector{Union{observed.inputs...}}()
    views = PSE.CompiledMetadataTable(NamedTuple{IDS}(map(id -> Vector{Union{observed.views[id]...}}(), IDS)))
    environment = PSE._freeze_environment_binding_schema(env)
    fresh() = PSE._prepare_simulation!(close_registry(scene()); steps=0, outputs=:all,
        constants=PSE.Constants(), environment_schema=environment, input_binding_storage=inputs, status_view_schema=views)
    batches = Dict(id => DataType[] for id in IDS)
    function observe(sim)
        for group in sim.execution_plan.groups, batch in group.batches
            remember!(batches[batch.application.id], typeof(batch))
        end
    end
    result = exercise!(fresh(), observe)
    iszero(result) || error("finite retry failed at checkpoint $result")
    schemas = NamedTuple{IDS}(map(id -> batch_schema(batches[id]), IDS))
    return PSE._prepare_execution_batch_schemas(fresh(), schemas)
end

const SIM = prepare()
qualify() = Cint(exercise!(SIM, ignore))
end
