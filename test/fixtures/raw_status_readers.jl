PSE.@process "input_recipe_aggregate" verbose=false
PSE.@process "input_recipe_empty" verbose=false

struct AggregateReader <: AbstractInput_Recipe_AggregateModel end
PSE.inputs_(::AggregateReader) = (values=Default(Float64[]),)
PSE.outputs_(::AggregateReader) = (total=0.0,)
function PSE.run!(::AggregateReader, status, environment, constants, context)
    status.total = sum(bound_input(context, :values); init=0.0)
    return nothing
end

struct EmptyModel <: AbstractInput_Recipe_EmptyModel end
PSE.inputs_(::EmptyModel) = NamedTuple()
PSE.outputs_(::EmptyModel) = NamedTuple()
PSE.run!(::EmptyModel, status, environment, constants, context) = nothing
