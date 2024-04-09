"""
    MultiScaleModel(model, mapping)

A structure to make a model multi-scale. It defines a mapping between the variables of a 
model and the nodes symbols from which the values are taken from.

# Arguments

- `model<:AbstractModel`: the model to make multi-scale
- `mapping<:Vector{Pair{Symbol,Union{AbstractString,Vector{AbstractString}}}}`: a vector of pairs of symbols and strings or vectors of strings

The mapping can be of the form:

1. `[:variable_name => "Plant"]`: We take one value from the Plant node
2. `[:variable_name => ["Leaf"]]`: We take a vector of values from the Leaf nodes
3. `[:variable_name => ["Leaf", "Internode"]]`: We take a vector of values from the Leaf and Internode nodes
4. `[:variable_name => "Plant" => :variable_name_in_plant_scale]`: We take one value from another variable name in the Plant node
5. `[:variable_name => ["Leaf" => :variable_name_1, "Internode" => :variable_name_2]]`: We take a vector of values from the Leaf and Internode nodes with different names
6. `[PreviousTimeStep(:variable_name) => ...]`: We flag the variable to be initialized with the value from the previous time step, and we do not use it to build the dep graph
7. `[:variable_name => :variable_name_from_another_model]`: We take the value from another model at the same scale but rename it
8. `[PreviousTimeStep(:variable_name),]`: We just flag the variable as a PreviousTimeStep to not use it to build the dep graph

Details about the different forms:

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

6. The variable `variable_name` of the model uses the value computed on the previous time-step. This implies that the variable is not used to build the dependency graph
because the dependency graph only applies on the current time-step. This is used to avoid circular dependencies when a variable depends on itself. The value can be initialized
in the Status if needed.

7. The variable `variable_name` of the model will be taken from another model at the same scale, but with another variable name.

8. The variable `variable_name` of the model is just flagged as a PreviousTimeStep variable, so it is not used to build the dependency graph.



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
MultiScaleModel{ToyCAllocationModel, Vector{Pair{Union{Symbol, PreviousTimeStep}, Union{Pair{String, Symbol}, Vector{Pair{String, Symbol}}}}}}(ToyCAllocationModel(), Pair{Union{Symbol, PreviousTimeStep}, Union{Pair{String, Symbol}, Vector{Pair{String, Symbol}}}}[:carbon_allocation => ["Leaf" => :carbon_allocation, "Internode" => :carbon_allocation]])
```

We can access the mapping and the model:

```jldoctest mylabel
julia> PlantSimEngine.mapping_(multiscale_model)
1-element Vector{Pair{Union{Symbol, PreviousTimeStep}, Union{Pair{String, Symbol}, Vector{Pair{String, Symbol}}}}}:
 :carbon_allocation => ["Leaf" => :carbon_allocation, "Internode" => :carbon_allocation]
```

```jldoctest mylabel
julia> PlantSimEngine.model_(multiscale_model)
ToyCAllocationModel()
```
"""
struct MultiScaleModel{T<:AbstractModel,V<:AbstractVector{Pair{A,Union{Pair{S,Symbol},Vector{Pair{S,Symbol}}}}} where {A<:Union{Symbol,PreviousTimeStep},S<:AbstractString}}
    model::T
    mapping::V

    function MultiScaleModel{T}(model::T, mapping) where {T<:AbstractModel}
        # Check that the variables in the mapping are variables of the model:
        model_variables = keys(variables(model))
        for i in mapping
            var = isa(i, PreviousTimeStep) ? i.variable : first(i)
            if !(var in model_variables)
                error("Mapping for model $model defines variable $var, but it is not a variable of the model.")
            end
        end

        # If the name of the variable mapped from the other scale is not given, we add it as the same of the variable name in the model. Cases:
        # 1. `[:variable_name => "Plant"]` # We take one value from the Plant node
        # 2. `[:variable_name => ["Leaf"]]` # We take a vector of values from the Leaf nodes
        # 3. `[:variable_name => ["Leaf", "Internode"]]` # We take a vector of values from the Leaf and Internode nodes
        # 4. `[:variable_name => "Plant" => :variable_name_in_plant_scale]` # We take one value from another variable name in the Plant node
        # 5. `[:variable_name => ["Leaf" => :variable_name_1, "Internode" => :variable_name_2]]` # We take a vector of values from the Leaf and Internode nodes with different names
        # 6. `[PreviousTimeStep(:variable_name) => ...]` # We flag the variable to be initialized with the value from the previous time step, and we do not use it to build the dep graph
        # 7. `[:variable_name => :variable_name_from_another_model]` # We take the value from another model at the same scale but rename it
        # 8. `[PreviousTimeStep(:variable_name),]` # We just flag the variable as a PreviousTimeStep to not use it to build the dep graph

        unfolded_mapping = Pair{Union{Symbol,PreviousTimeStep},Union{Pair{String,Symbol},Vector{Pair{String,Symbol}}}}[]
        for i in mapping
            push!(unfolded_mapping, _get_var(i))
        end

        new{T,typeof(unfolded_mapping)}(model, unfolded_mapping)
    end
end

# Case 1: [:variable_name => "Plant"]
function _get_var(i::Pair{Symbol,S}) where {S<:String}
    return (var=first(i), scales_mapping=last(i), var_new=var)
end

# Case 2 and 3: [:variable_name => ["Leaf", "Internode"]] or [:variable_name => ["Leaf"]]
function _get_var(i::Pair{Symbol,T}) where {T<:AbstractVector{<:AbstractString}}
    return first(i) => [scale => first(i) for scale in last(i)]
end

# Case 4: [:variable_name => "Plant" => :variable_name_in_plant_scale]
function _get_var(i::Pair{Symbol,Pair{S,Symbol}}) where {S<:String}
    return first(i) => last(i) => first(i)
end

# Case 5: [:variable_name => ["Leaf" => :variable_name_1, "Internode" => :variable_name_2]]
function _get_var(i::Pair{Symbol,T}) where {T<:AbstractVector{Pair{S,Symbol}} where {S<:AbstractString}}
    return first(i) => last(i) # Note that we do not need to do anything here, the mapping is already in the right format
end

# Case 6: [PreviousTimeStep(:variable_name) => ...]
function _get_var(i::Pair{PreviousTimeStep,Any})
    vars = _get_var(i.first.variable => i.second) # Leverage the other methods here
    return first(i) => last(vars) # And put back the PreviousTimeStep as the first element
end

# Case 7: [:variable_name => :variable_name_from_another_model]
function _get_var(i::Pair{Symbol,Symbol})
    return first(i) => "" => last(i)
end

# Case 8: [PreviousTimeStep(:variable_name),]
function _get_var(i::PreviousTimeStep)
    return i => "" => i.variable
end



function MultiScaleModel(model::T, mapping) where {T<:AbstractModel}
    MultiScaleModel{T}(model, mapping)
end
MultiScaleModel(; model, mapping) = MultiScaleModel(model, mapping)

mapping_(m::MultiScaleModel) = m.mapping
model_(m::MultiScaleModel) = m.model
inputs_(m::MultiScaleModel) = inputs_(m.model)
outputs_(m::MultiScaleModel) = outputs_(m.model)
get_models(m::MultiScaleModel) = [model_(m)] # Get the models of a MultiScaleModel:
# Note: it is returning a vector of models, because in this case the user provided a single MultiScaleModel instead of a vector of.
get_status(m::MultiScaleModel) = nothing
get_mapping(m::MultiScaleModel{T,S}) where {T,S} = mapping_(m)