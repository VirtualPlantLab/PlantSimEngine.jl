PlantSimEngine.@process "toy_selective_call_controller" verbose = false
PlantSimEngine.@process "toy_stock_writer" verbose = false

"""
    ToySelectiveCallControllerModel(
        ;
        increment=1.0,
        threshold=22.0,
        max_iterations=100,
        selected_object,
    )

Start from the controller's environmental temperature, run `selected_object`,
and increase the temperature by `increment` until the reader reports a value
strictly above `threshold`. Publish only that accepted calculation.

This deliberately artificial iteration illustrates selective hard calls,
not a physical temperature solver. A fixed increment keeps it reproducible;
`max_iterations` bounds the number of trial evaluations.
"""
struct ToySelectiveCallControllerModel{T} <:
       AbstractToy_Selective_Call_ControllerModel
    increment::T
    threshold::T
    max_iterations::Int
    selected_object::Symbol
end

function ToySelectiveCallControllerModel(
    ;
    increment=1.0,
    threshold=22.0,
    max_iterations::Integer=100,
    selected_object,
)
    increment, threshold = promote(float(increment), float(threshold))
    isfinite(increment) && increment > zero(increment) || throw(ArgumentError(
        "increment must be finite and positive.",
    ))
    isfinite(threshold) || throw(ArgumentError("threshold must be finite."))
    max_iterations > 0 || throw(ArgumentError("max_iterations must be positive."))
    T = typeof(increment)
    return ToySelectiveCallControllerModel{T}(
        increment,
        threshold,
        Int(max_iterations),
        Symbol(selected_object),
    )
end

PlantSimEngine.inputs_(::ToySelectiveCallControllerModel) = NamedTuple()
PlantSimEngine.environment_inputs_(model::ToySelectiveCallControllerModel) =
    (T=zero(model.threshold),)
PlantSimEngine.dep(::ToySelectiveCallControllerModel) = (
    readers=Call(Many(
        scale=:Leaf,
        process=:toy_environment_reader,
        within=Subtree(),
    )),
)
function PlantSimEngine.outputs_(model::ToySelectiveCallControllerModel)
    initial = zero(model.threshold)
    return (
        target_count=0,
        initial_temperature=initial,
        iterations=0,
        accepted_temperature_seen=initial,
    )
end

function PlantSimEngine.run!(
    model::ToySelectiveCallControllerModel,
    status,
    environment,
    constants,
    context,
)
    targets = call_targets(context, :readers)
    status.target_count = length(targets)
    selected = only(call_targets(
        context,
        :readers;
        objects=(ObjectId(model.selected_object),),
    ))

    temperature = environment.T
    status.initial_temperature = temperature
    status.iterations = 0
    for iteration in 1:model.max_iterations
        run_call!(
            selected;
            sampled_environment=(T=temperature,),
            publish=false,
        )
        status.iterations = iteration
        if selected.status.temperature_seen > model.threshold
            run_call!(
                selected;
                sampled_environment=(T=temperature,),
                publish=true,
            )
            status.accepted_temperature_seen = selected.status.temperature_seen
            return nothing
        end
        temperature = selected.status.temperature_seen + model.increment
    end
    error(
        "Toy temperature iteration did not exceed $(model.threshold) " *
        "after $(model.max_iterations) iterations.",
    )
end

"""
    ToyStockWriterModel(value)

Write one configured stock value. Several named applications of this model can
demonstrate canonical writer ordering and stream-only output routing.
"""
struct ToyStockWriterModel{T} <: AbstractToy_Stock_WriterModel
    value::T
end

function ToyStockWriterModel(value::Real)
    parameter = float(value)
    return ToyStockWriterModel{typeof(parameter)}(parameter)
end

PlantSimEngine.inputs_(::ToyStockWriterModel) = NamedTuple()
PlantSimEngine.outputs_(model::ToyStockWriterModel) =
    (stock=zero(model.value),)

function PlantSimEngine.run!(
    model::ToyStockWriterModel,
    status,
    environment,
    constants,
    context,
)
    status.stock = model.value
    return nothing
end
