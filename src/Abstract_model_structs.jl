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