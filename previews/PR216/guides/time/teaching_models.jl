module TeachingTimeModels

using PlantSimEngine

export HourlyWaterRate, SumWaterAmounts, WeeklyWaterAmount

PlantSimEngine.@process "teaching_water_rate" verbose=false
PlantSimEngine.@process "teaching_water_amount" verbose=false
PlantSimEngine.@process "teaching_weekly_water_amount" verbose=false

"""Publish a supplied constant uptake rate, in mg of water per leaf per second."""
struct HourlyWaterRate <: AbstractTeaching_Water_RateModel end

PlantSimEngine.inputs_(::HourlyWaterRate) = (rate_mg_s=Required(Real),)
PlantSimEngine.outputs_(::HourlyWaterRate) = (water_rate_mg_s=0.0,)

function PlantSimEngine.run!(::HourlyWaterRate, status, environment, constants, context)
    status.water_rate_mg_s = status.rate_mg_s
    return nothing
end

"""Add already converted water amounts, in mg, from the selected sources."""
struct SumWaterAmounts <: AbstractTeaching_Water_AmountModel end

PlantSimEngine.inputs_(::SumWaterAmounts) = (amounts_mg=Required(AbstractVector{<:Real}),)
PlantSimEngine.outputs_(::SumWaterAmounts) = (water_amount_mg=0.0,)

function PlantSimEngine.run!(::SumWaterAmounts, status, environment, constants, context)
    status.water_amount_mg = sum(status.amounts_mg)
    return nothing
end

"""Keep a separately named weekly total, in mg of water per plant."""
struct WeeklyWaterAmount <: AbstractTeaching_Weekly_Water_AmountModel end

PlantSimEngine.inputs_(::WeeklyWaterAmount) = (amounts_mg=Required(AbstractVector{<:Real}),)
PlantSimEngine.outputs_(::WeeklyWaterAmount) = (weekly_water_mg=0.0,)

function PlantSimEngine.run!(::WeeklyWaterAmount, status, environment, constants, context)
    status.weekly_water_mg = sum(status.amounts_mg)
    return nothing
end

# These constant-rate teaching models isolate temporal sampling. Their variable
# contracts are deliberately undeclared: the pages explain the explicit adapter
# required when a contracted rate is converted to a contracted amount.

end # module
