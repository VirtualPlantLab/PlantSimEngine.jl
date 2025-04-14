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