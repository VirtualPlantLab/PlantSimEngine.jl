PlantSimEngine.@process "toy_selective_call_controller" verbose = false
PlantSimEngine.@process "toy_stock_writer" verbose = false

"""
    ToySelectiveCallControllerModel(
        trial_temperatures,
        accepted_temperature;
        selected_object,
    )

Resolve several hard-call targets, run `selected_object` for several
unpublished trials, then publish one accepted result.
"""
struct ToySelectiveCallControllerModel{T} <:
       AbstractToy_Selective_Call_ControllerModel
    trial_temperatures::NTuple{2,T}
    accepted_temperature::T
    selected_object::Symbol
end

function ToySelectiveCallControllerModel(
    trial_temperatures::Tuple,
    accepted_temperature,
    ;
    selected_object,
)
    length(trial_temperatures) == 2 || error(
        "ToySelectiveCallControllerModel needs exactly two trial temperatures.",
    )
    values = promote(
        float(trial_temperatures[1]),
        float(trial_temperatures[2]),
        float(accepted_temperature),
    )
    T = typeof(values[1])
    return ToySelectiveCallControllerModel{T}(
        (values[1], values[2]),
        values[3],
        Symbol(selected_object),
    )
end

PlantSimEngine.inputs_(::ToySelectiveCallControllerModel) = NamedTuple()
function PlantSimEngine.outputs_(model::ToySelectiveCallControllerModel)
    initial = zero(model.accepted_temperature)
    return (
        target_count=0,
        trial_temperature_seen=initial,
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

    for temperature in model.trial_temperatures
        run_call!(
            selected;
            sampled_environment=(T=temperature,),
            publish=false,
        )
    end
    status.trial_temperature_seen = selected.status.temperature_seen

    run_call!(
        selected;
        sampled_environment=(T=model.accepted_temperature,),
        publish=true,
    )
    status.accepted_temperature_seen = selected.status.temperature_seen
    return nothing
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
