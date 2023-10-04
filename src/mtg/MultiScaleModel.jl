"""
    MultiScaleModel(model, mapping)

A structure to make a model multi-scale. It defines a mapping between the variables of a 
model and the nodes symbols from which the values are taken from.

# Arguments

- `model<:AbstractModel`: the model to make multi-scale
- `mapping<:Vector{Pair{Symbol,Union{AbstractString,Vector{AbstractString}}}}`: a vector of pairs of symbols and strings or vectors of strings

The mapping can be of the form `[:variable => ["Leaf", "Internode"]]` or `[:variable => "Plant"]`. 

In the first form, the variable `variable` of the model will be taken from the `Leaf` and `Internode` nodes, and will 
be available in the status as a vector of values. The order of the values in the vector is the same as the order of the nodes in the mtg.

In the second form, the variable `variable` of the model will be taken from the `Plant` node, assuming only one node has the `Plant` symbol.
In this case the value available from the status will be a scalar.

Note that the mapping does not make any copy of the values, it only references them. This means that if the values are updated in the status
of one node, they will be updated in the other nodes.

# Examples

```jldoctest mylabel
julia> using PlantSimEngine
```

Let's take a model:

```jldoctest mylabel
julia> model = ToyCAllocationModel()
ToyCAllocationModel()
```

We can make it multi-scale by defining a mapping between the variables of the model and the nodes symbols from which the values are taken from:

For example, if the `carbon_allocation` comes from the `Leaf` and `Internode` nodes, we can define the mapping as follows:

```jldoctest mylabel
julia> mapping = [:carbon_allocation => ["Leaf", "Internode"]]
1-element Vector{Pair{Symbol, Vector{String}}}:
 :carbon_allocation => ["Leaf", "Internode"]
```

The mapping is a vector of pairs of symbols and strings or vectors of strings. In this case, we have only one pair to define the mapping
between the `carbon_allocation` variable and the `Leaf` and `Internode` nodes.

We can now make the model multi-scale by passing the model and the mapping to the `MultiScaleModel` constructor :

```jldoctest mylabel
julia> multiscale_model = MultiScaleModel(model, mapping)
MultiScaleModel{ToyCAllocationModel, String}(ToyCAllocationModel(), ["carbon_allocation" => ["Leaf", "Internode"]])
```

We can access the mapping and the model:

```jldoctest mylabel
julia> PlantSimEngine.mapping_(multiscale_model)
1-element Vector{Pair{Symbol, Vector{String}}}:
 :carbon_allocation => ["Leaf", "Internode"]
```

```jldoctest mylabel
julia> PlantSimEngine.model_(multiscale_model)
ToyCAllocationModel()
```
"""
struct MultiScaleModel{T<:AbstractModel,S<:AbstractString}
    model::T
    mapping::Vector{Pair{Symbol,Union{S,Vector{S}}}}
end

function MultiScaleModel(model, mapping)
    MultiScaleModel(
        model,
        Vector{Pair{Symbol,Union{String,Vector{String}}}}(mapping)
    )
end

MultiScaleModel(; model, mapping) = MultiScaleModel(model, mapping)

mapping_(m::MultiScaleModel) = m.mapping
model_(m::MultiScaleModel) = m.model