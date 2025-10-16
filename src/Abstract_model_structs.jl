"""
Abstract model type. All models are subtypes of this one.
"""
abstract type AbstractModel end

"""
    process(x)

Returns the process name of the model `x`.
"""
# process(x) = error("process() is not defined for $(typeof(x))")
# process(x::AbstractModel) = error("process() is not defined for $(x), did you forget to define it?")
process(x::A) where {A<:AbstractModel} = process_(supertype(A))

# For the models given with their process name:
process(x::Pair{Symbol,A}) where {A<:AbstractModel} = first(x)
process_(x) = error("process() is not defined for $(x)")

"""
    model_(m::AbstractModel)

Get the model of an AbstractModel (it is the model itself if it is not a MultiScaleModel).
"""
model_(m::AbstractModel) = m
get_models(m::AbstractModel) = [model_(m)] # Get the models of an AbstractModel
# Note: it is returning a vector of models, because in this case the user provided a single model instead of a vector of.
get_status(m::AbstractModel) = nothing
get_mapped_variables(m::AbstractModel) = Pair{Symbol,String}[]


#using Dates
struct TimestepRange 
    lower_bound::Period
    upper_bound::Period
end

# Default, no specified range, meaning the model either doesn't depend on time or uses the simulation's default (eg smallest) timestep
TimestepRange() = TimestepRange(Second(0), Second(0))
# Only a single timestep type possible
TimestepRange(p::Period) = TimestepRange(p, p)

"""
    timestep_range_(tsr::TimestepRange)

Return the model's valid range for timesteps (which corresponds to the simulation base timestep in the default case).
"""
function timestep_range_(model::AbstractModel)
    return TimestepRange()
end

"""
    timestep_valid(tsr::TimestepRange)

Checks whether a TimestepRange
"""
timestep_valid(tsr::TimestepRange) = tsr.lower_bound <= tsr.upper_bound

function model_timestep_range_compatible_with_timestep(tsr::TimestepRange, p::Period) 
    if !timestep_valid(tsr)
        return false
    end

    # 0 means any timestep is valid, no timestep constraints
    if tsr.upper_bound == Seconds(0)
        return true
    end

    return p >= tsr.lower_bound && p <= tsr.lower_bound
end

# TODO should i set all timestep ranges to default and hope the modeler gets it right or should i force them to write something ?