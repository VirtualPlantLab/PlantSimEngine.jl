"""
    MultiScaleModel(model, mapping)

A structure to make a model multi-scale. It defines a mapping between the variables of a 
model and the nodes symbols from which the values are taken from.

# Arguments

- `model<:AbstractModel`: the model to make multi-scale
- `mapping<:Vector{Pair{Symbol,Union{AbstractString,Vector{AbstractString}}}}`: a vector of pairs of symbols and strings or vectors of strings

The mapping can be of the form:
1. `[:variable_name => "Plant"]`
2. `[:variable_name => ["Leaf"]]`
3. `[:variable_name => ["Leaf", "Internode"]]`
4. `[:variable_name => "Plant" => :variable_name_in_plant_scale]`
5. `[:variable_name => ["Leaf" => :variable_name_1, "Internode" => :variable_name_2]]`

Explanation of the forms:

1. The variable `variable_name` of the model will be taken from the `Plant` node, assuming only one node has the `Plant` symbol.
In this case the value available from the status will be a scalar, and so the user must guaranty that only one node of type `Plant` is available in the MTG.

2. The variable `variable_name` of the model will be taken from the `Leaf` nodes. Notice it is given as a vector, indicating that the values will be taken 
from all the nodes of type `Leaf`. The model should be able to handle a vector of values. Note that even if there is only one node of type `Leaf`, the value
will be taken as a vector of one element.

3. The variable `variable_name` of the model will be taken from the `Leaf` and `Internode` nodes. The values will be taken from all the nodes of type `Leaf` 
and `Internode`.

4. The variable `variable_name` of the model will be taken from the variable called `variable_name_in_plant_scale` in the `Plant` node. This is useful
when the variable name in the model is different from the variable name in the scale it is taken from.

5. The variable `variable_name` of the model will be taken from the variable called `variable_name_1` in the `Leaf` node and `variable_name_2` in the `Internode` node.

Note that the mapping does not make any copy of the values, it only references them. This means that if the values are updated in the status
of one node, they will be updated in the other nodes.

# Examples

```jldoctest mylabel
julia> using PlantSimEngine;
```

Including example processes and models:

```jldoctest mylabel
julia> using PlantSimEngine.Examples;
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
julia> multiscale_model = PlantSimEngine.MultiScaleModel(model, mapping)
MultiScaleModel{ToyCAllocationModel, String}(ToyCAllocationModel(), Pair{Symbol, Union{String, Vector{String}}}[:carbon_allocation => ["Leaf", "Internode"]])
```

We can access the mapping and the model:

```jldoctest mylabel
julia> PlantSimEngine.mapping_(multiscale_model)
1-element Vector{Pair{Symbol, Union{String, Vector{String}}}}:
 :carbon_allocation => ["Leaf", "Internode"]
```

```jldoctest mylabel
julia> PlantSimEngine.model_(multiscale_model)
ToyCAllocationModel()
```
"""
struct MultiScaleModel{T<:AbstractModel,V<:AbstractVector{Pair{Symbol,Union{Pair{S,Symbol},Vector{Pair{S,Symbol}}}}} where {S<:AbstractString}}
    model::T
    mapping::V

    function MultiScaleModel{T}(model::T, mapping) where {T<:AbstractModel}
        # Check that the variables in the mapping are variables of the model:
        model_variables = variables(model)
        for (var, scales_mapping) in mapping
            if !(var in model_variables)
                error("Mapping for model $model defines variable $var, but it is not a variable of the model.")
            end
        end

        # If the name of the variable mapped from the other scale is not given, we add it as the same of the variable name in the model. Cases:
        # 1. `[:variable_name => "Plant"]`
        # 2. `[:variable_name => ["Leaf"]]`
        # 3. `[:variable_name => ["Leaf", "Internode"]]`
        # 4. `[:variable_name => "Plant" => :variable_name_in_plant_scale]`
        # 5. `[:variable_name => ["Leaf" => :variable_name_1, "Internode" => :variable_name_2]]`

        unfolded_mapping = Pair{Symbol,Union{Pair{String,Symbol},Vector{Pair{String,Symbol}}}}[]
        for (var, scales_mapping) in mapping
            if isa(scales_mapping, AbstractString)
                # Case 1, add the variable name in the model as the variable name in the scale:
                push!(unfolded_mapping, var => scales_mapping => var)
            elseif isa(scales_mapping, AbstractVector{String})
                # Case 2 and 3, add the variable name in the model as the variable name in the scale:
                push!(unfolded_mapping, var => [scale => var for scale in scales_mapping])
            else
                # Case 3 and 4, everything we need is already in the scales_mapping:
                push!(unfolded_mapping, var => scales_mapping)
            end
        end

        new{T,typeof(unfolded_mapping)}(model, unfolded_mapping)
    end
end

function MultiScaleModel(model::T, mapping) where {T<:AbstractModel}
    MultiScaleModel{T}(model, mapping)
end
MultiScaleModel(; model, mapping) = MultiScaleModel(model, mapping)

mapping_(m::MultiScaleModel) = m.mapping
model_(m::MultiScaleModel) = m.model