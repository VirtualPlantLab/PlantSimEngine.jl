PlantSimEngine.@process "toy_development" verbose = false
PlantSimEngine.@process "toy_daily_development" verbose = false

"""
    ToyDevelopmentModel(efficiency)

Compute one growth increment from required thermal time and an optional stress
factor.

# Inputs

- `TT`: required thermal time for the current step.
- `stress`: dimensionless stress factor, defaulting to `1.0`.

# Outputs

- `growth`: growth increment for the current step.
"""
struct ToyDevelopmentModel{T} <: AbstractToy_DevelopmentModel
    efficiency::T
end

function ToyDevelopmentModel(efficiency::Real)
    parameter = float(efficiency)
    return ToyDevelopmentModel{typeof(parameter)}(parameter)
end

PlantSimEngine.inputs_(::ToyDevelopmentModel) = (
    TT=Required(Real),
    stress=Default(1.0),
)
PlantSimEngine.outputs_(model::ToyDevelopmentModel) = (
    growth=zero(model.efficiency),
)

function PlantSimEngine.run!(
    model::ToyDevelopmentModel,
    status,
    environment,
    constants,
    context,
)
    status.growth = model.efficiency * status.TT * status.stress
    return nothing
end

"""
    ToyDailyDevelopmentModel(increment)

Accumulate one configured growth increment every 24 simulation steps. The model
declares this default cadence and hold-last output semantics.
"""
struct ToyDailyDevelopmentModel{T} <:
       AbstractToy_Daily_DevelopmentModel
    increment::T
end

function ToyDailyDevelopmentModel(increment::Real)
    parameter = float(increment)
    return ToyDailyDevelopmentModel{typeof(parameter)}(parameter)
end

PlantSimEngine.inputs_(::ToyDailyDevelopmentModel) = NamedTuple()
PlantSimEngine.outputs_(model::ToyDailyDevelopmentModel) = (
    daily_growth=zero(model.increment),
)
PlantSimEngine.timespec(::Type{<:ToyDailyDevelopmentModel}) =
    ClockSpec(24.0, 1.0)
PlantSimEngine.output_policy(::Type{<:ToyDailyDevelopmentModel}) = (
    daily_growth=HoldLast(),
)

function PlantSimEngine.run!(
    model::ToyDailyDevelopmentModel,
    status,
    environment,
    constants,
    context,
)
    status.daily_growth += model.increment
    return nothing
end
