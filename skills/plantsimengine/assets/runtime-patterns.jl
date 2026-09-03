module RuntimePatternsExample

using Dates
using PlantSimEngine

export HourlySignal, HoldLastSignal, LaggedIncrement
export CallCounter, PublishingController
export temporal_scenario, hard_call_scenario
export SIGNAL_CONTRACT, COUNT_CONTRACT

PlantSimEngine.@process "pedagogical_temporal_signal" verbose=false
PlantSimEngine.@process "pedagogical_temporal_observation" verbose=false
PlantSimEngine.@process "pedagogical_lagged_increment" verbose=false
PlantSimEngine.@process "pedagogical_call_counter" verbose=false
PlantSimEngine.@process "pedagogical_publishing_controller" verbose=false

const SIGNAL_CONTRACT = VariableContract(
    unit=:arbitrary_signal_unit,
    basis=:object,
    temporal=:instantaneous,
    aggregation=:state,
    extent=:intensive,
)

const COUNT_CONTRACT = VariableContract(
    unit=:count,
    basis=:model_invocation,
    temporal=:instantaneous,
    aggregation=:state,
    extent=:intensive,
)

struct HourlySignal{T} <: AbstractPedagogical_Temporal_SignalModel
    increment::T
end

PlantSimEngine.inputs_(::HourlySignal) = NamedTuple()
PlantSimEngine.outputs_(model::HourlySignal) = (signal=zero(model.increment),)
PlantSimEngine.environment_inputs_(::HourlySignal) = NamedTuple()
PlantSimEngine.environment_outputs_(::HourlySignal) = NamedTuple()
PlantSimEngine.variable_contracts_(::HourlySignal) = (signal=SIGNAL_CONTRACT,)
PlantSimEngine.Authoring.model_metadata(::HourlySignal) = (
    hypothesis="The illustrative signal increases by a fixed amount at every source call.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)
PlantSimEngine.Authoring.parameter_metadata(::HourlySignal) = (
    increment=(
        description="Illustrative signal increment per source call.",
        unit=:arbitrary_signal_unit,
    ),
)

function PlantSimEngine.run!(
    model::HourlySignal,
    status,
    environment,
    constants,
    context,
)
    status.signal += model.increment
    return nothing
end

struct HoldLastSignal <: AbstractPedagogical_Temporal_ObservationModel end

PlantSimEngine.inputs_(::HoldLastSignal) = (held_signal=Required(Real),)
PlantSimEngine.outputs_(::HoldLastSignal) = (observed_signal=0.0,)
PlantSimEngine.environment_inputs_(::HoldLastSignal) = NamedTuple()
PlantSimEngine.environment_outputs_(::HoldLastSignal) = NamedTuple()
PlantSimEngine.variable_contracts_(::HoldLastSignal) = (
    held_signal=SIGNAL_CONTRACT,
    observed_signal=SIGNAL_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::HoldLastSignal) = (
    hypothesis="A slower observer reads the last available illustrative signal.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)

function PlantSimEngine.run!(
    ::HoldLastSignal,
    status,
    environment,
    constants,
    context,
)
    status.observed_signal = status.held_signal
    return nothing
end

struct LaggedIncrement{T} <: AbstractPedagogical_Lagged_IncrementModel
    increment::T
end

PlantSimEngine.inputs_(::LaggedIncrement) = (previous_state=Required(Real),)
PlantSimEngine.outputs_(model::LaggedIncrement) = (state=zero(model.increment),)
PlantSimEngine.environment_inputs_(::LaggedIncrement) = NamedTuple()
PlantSimEngine.environment_outputs_(::LaggedIncrement) = NamedTuple()
PlantSimEngine.variable_contracts_(::LaggedIncrement) = (
    previous_state=SIGNAL_CONTRACT,
    state=SIGNAL_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::LaggedIncrement) = (
    hypothesis="Current state equals the explicitly lagged state plus a fixed increment.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)
PlantSimEngine.Authoring.parameter_metadata(::LaggedIncrement) = (
    increment=(
        description="Increment added to the previous-timestep state.",
        unit=:arbitrary_signal_unit,
    ),
)

function PlantSimEngine.run!(
    model::LaggedIncrement,
    status,
    environment,
    constants,
    context,
)
    status.state = status.previous_state + model.increment
    return nothing
end

struct CallCounter{T} <: AbstractPedagogical_Call_CounterModel
    increment::T
end

PlantSimEngine.inputs_(::CallCounter) = NamedTuple()
PlantSimEngine.outputs_(model::CallCounter) = (
    value=zero(model.increment),
    calls=0,
)
PlantSimEngine.environment_inputs_(::CallCounter) = NamedTuple()
PlantSimEngine.environment_outputs_(::CallCounter) = NamedTuple()
PlantSimEngine.variable_contracts_(::CallCounter) = (
    value=SIGNAL_CONTRACT,
    calls=COUNT_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::CallCounter) = (
    hypothesis="Each manual call increments one illustrative value and its call count.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)
PlantSimEngine.Authoring.parameter_metadata(::CallCounter) = (
    increment=(
        description="Illustrative value increment per manual call.",
        unit=:arbitrary_signal_unit,
    ),
)

function PlantSimEngine.run!(
    model::CallCounter,
    status,
    environment,
    constants,
    context,
)
    status.value += model.increment
    status.calls += one(status.calls)
    return nothing
end

struct PublishingController <: AbstractPedagogical_Publishing_ControllerModel end

PlantSimEngine.inputs_(::PublishingController) = NamedTuple()
PlantSimEngine.outputs_(::PublishingController) = (
    trial_value=0.0,
    accepted_value=0.0,
)
PlantSimEngine.environment_inputs_(::PublishingController) = NamedTuple()
PlantSimEngine.environment_outputs_(::PublishingController) = NamedTuple()
PlantSimEngine.variable_contracts_(::PublishingController) = (
    trial_value=SIGNAL_CONTRACT,
    accepted_value=SIGNAL_CONTRACT,
)
PlantSimEngine.Authoring.model_metadata(::PublishingController) = (
    hypothesis="The controller publishes only its second, accepted manual call.",
    reference=nothing,
    maturity=:pedagogical_non_calibrated,
    validation=:structural_tests_only,
)

function PlantSimEngine.run!(
    ::PublishingController,
    status,
    environment,
    constants,
    context,
)
    trial = only(run_call!(context, :counter; publish=false))
    status.trial_value = trial.status.value

    accepted = only(run_call!(context, :counter; publish=true))
    status.accepted_value = accepted.status.value
    return nothing
end

"""Build one scenario with `HoldLast` and an explicit previous-timestep state."""
function temporal_scenario(::Type{T}=Float32) where {T<:Real}
    return CompositeModel(
        Object(
            :scene;
            scale=:Scene,
            kind=:scene,
            status=Status(previous_state=T(5), state=T(5)),
        );
        applications=(
            ModelSpec(
                HourlySignal(T(1));
                name=:hourly_signal,
                on=One(scale=:Scene),
                every=Hour(1),
            ),
            ModelSpec(
                HoldLastSignal();
                name=:held_observer,
                on=One(scale=:Scene),
                inputs=(
                    held_signal=One(
                        within=Self(),
                        application=:hourly_signal,
                        var=:signal,
                        policy=HoldLast(),
                    ),
                ),
                every=Hour(2),
            ),
            ModelSpec(
                LaggedIncrement(T(1));
                name=:lagged_increment,
                on=One(scale=:Scene),
                inputs=(
                    PreviousTimeStep(:previous_state) => One(
                        within=Self(),
                        application=:lagged_increment,
                        var=:state,
                    ),
                ),
                every=Hour(1),
            ),
        ),
        environment=(duration=Hour(1),),
        type_promotion=Dict(Float64 => T),
    )
end

"""Build a controller-owned hard call with trial and accepted publication."""
function hard_call_scenario(::Type{T}=Float32) where {T<:Real}
    return CompositeModel(
        Object(:scene; scale=:Scene, kind=:scene),
        Object(
            :counter_object;
            scale=:Counter,
            kind=:counter,
            parent=:scene,
        );
        applications=(
            ModelSpec(
                PublishingController();
                name=:publishing_controller,
                on=One(scale=:Scene),
                calls=(
                    counter=One(
                        scale=:Counter,
                        application=:call_counter,
                    ),
                ),
            ),
            ModelSpec(
                CallCounter(T(1));
                name=:call_counter,
                on=One(scale=:Counter),
            ),
        ),
        environment=(duration=Hour(1),),
        type_promotion=Dict(Float64 => T),
    )
end

end # module RuntimePatternsExample
