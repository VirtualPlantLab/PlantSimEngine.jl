"""
    MultiScaleModel(model, mapped_variables)

A structure to make a model multi-scale. It defines a mapping between the variables of a 
model and the nodes symbols from which the values are taken from.

# Arguments

- `model<:AbstractModel`: the model to make multi-scale
- `mapped_variables<:Vector{Pair{Symbol,Union{AbstractString,Vector{AbstractString}}}}`: a vector of pairs of symbols and strings or vectors of strings

The mapped_variables argument can be of the form:

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
julia> mapped_variables=[:carbon_allocation => ["Leaf", "Internode"]]
1-element Vector{Pair{Symbol, Vector{String}}}:
 :carbon_allocation => ["Leaf", "Internode"]
```

The mapped_variables argument is a vector of pairs of symbols and strings or vectors of strings. In this case, we have only one pair to define the mapping
between the `carbon_allocation` variable and the `Leaf` and `Internode` nodes.

We can now make the model multi-scale by passing the model and the mapped variables to the `MultiScaleModel` constructor :

```jldoctest mylabel
julia> multiscale_model = PlantSimEngine.MultiScaleModel(model, mapped_variables)
MultiScaleModel{ToyCAllocationModel, Vector{Pair{Union{Symbol, PreviousTimeStep}, Union{Pair{String, Symbol}, Vector{Pair{String, Symbol}}}}}}(ToyCAllocationModel(), Pair{Union{Symbol, PreviousTimeStep}, Union{Pair{String, Symbol}, Vector{Pair{String, Symbol}}}}[:carbon_allocation => ["Leaf" => :carbon_allocation, "Internode" => :carbon_allocation]])
```

We can access the mapped variables and the model:

```jldoctest mylabel
julia> PlantSimEngine.mapped_variables_(multiscale_model)
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
    mapped_variables::V

    function MultiScaleModel{T}(model::T, mapped_variables) where {T<:AbstractModel}
        # Check that the variables in the mapping are variables of the model:
        model_variables = keys(variables(model))
        for i in mapped_variables
            # If the var is a PreviousTimeStep, we take the variable name, else take the first element of the pair:
            var = isa(i, PreviousTimeStep) ? i.variable : first(i)

            # If it was a pair, the first element can still be a PreviousTimeStep, so we take the variable name:
            var = isa(var, PreviousTimeStep) ? var.variable : var

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

        process_ = process(model)
        unfolded_mapping = Pair{Union{Symbol,PreviousTimeStep},Union{Pair{String,Symbol},Vector{Pair{String,Symbol}}}}[]
        for i in mapped_variables
            push!(unfolded_mapping, _get_var(isa(i, PreviousTimeStep) ? i : Pair(i.first, i.second), process_))
            # Note: We are using Pair(i.first, i.second) to make sure the Pair is specialized enough, because sometimes the vector in the mapping made the Pair not specialized enough e.g. [:v1 => "S" => :v2,:v3 => "S"] makes the pairs `Pair{Symbol, Any}`.
        end

        new{T,typeof(unfolded_mapping)}(model, unfolded_mapping)
    end
end

# Method used when the vector in the mapping made the Pair not specialized enough e.g. [:v1 => "S" => :v2,:v3 => "S"] makes the pairs `Pair{Symbol, Any}`.
function _get_var(i::Pair{Symbol,Any}, proc::Symbol=:unknown)
    return _get_var(first(i) => last(i), proc)
end

# Case 1: [:variable_name => "Plant"]
function _get_var(i::Pair{Symbol,S}, proc::Symbol=:unknown) where {S<:String}
    return first(i) => last(i) => first(i)
end

# Case 2 and 3: [:variable_name => ["Leaf", "Internode"]] or [:variable_name => ["Leaf"]]
function _get_var(i::Pair{Symbol,T}, proc::Symbol=:unknown) where {T<:AbstractVector{<:AbstractString}}
    return first(i) => [scale => first(i) for scale in last(i)]
end

# Case 4: [:variable_name => "Plant" => :variable_name_in_plant_scale], nothing to do, the mapping is already in the right format
function _get_var(i::Pair{Symbol,Pair{S,Symbol}}, proc::Symbol=:unknown) where {S<:String}
    return i
end

# Case 5: [:variable_name => ["Leaf" => :variable_name_1, "Internode" => :variable_name_2]]
function _get_var(i::Pair{Symbol,T}, proc::Symbol=:unknown) where {T<:AbstractVector{Pair{S,Symbol}} where {S<:AbstractString}}
    return i # Note that we do not need to do anything here, the mapping is already in the right format
end

# Case 6: [PreviousTimeStep(:variable_name) => ...]
function _get_var(i::Pair{PreviousTimeStep,T}, proc::Symbol=:unknown) where {T}
    vars = _get_var(i.first.variable => i.second, proc) # Leverage the other methods here
    return PreviousTimeStep(first(i).variable, proc) => last(vars) # And put back the PreviousTimeStep as the first element
end

# Case 7: [:variable_name => :variable_name_from_another_proc]
function _get_var(i::Pair{Symbol,Symbol}, proc::Symbol=:unknown)
    return first(i) => "" => last(i)
end

# Case 8: [PreviousTimeStep(:variable_name),]
function _get_var(i::PreviousTimeStep, proc::Symbol=:unknown)
    return PreviousTimeStep(i.variable, proc) => "" => i.variable
end



function MultiScaleModel(model::T, mapped_variables) where {T<:AbstractModel}
    MultiScaleModel{T}(model, mapped_variables)
end
MultiScaleModel(; model, mapped_variables) = MultiScaleModel(model, mapped_variables)

mapped_variables_(m::MultiScaleModel) = m.mapped_variables
model_(m::MultiScaleModel) = m.model
inputs_(m::MultiScaleModel) = inputs_(m.model)
outputs_(m::MultiScaleModel) = outputs_(m.model)
get_models(m::MultiScaleModel) = [model_(m)] # Get the models of a MultiScaleModel:
# Note: it is returning a vector of models, because in this case the user provided a single MultiScaleModel instead of a vector of.
get_status(m::MultiScaleModel) = nothing
get_mapped_variables(m::MultiScaleModel{T,S}) where {T,S} = mapped_variables_(m)