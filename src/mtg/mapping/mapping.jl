"""
    AbstractNodeMapping

Abstract type for the type of node mapping, *e.g.* single node mapping or multiple node mapping.
"""
abstract type AbstractNodeMapping end

"""
    SingleNodeMapping(scale)

Type for the single node mapping, *e.g.* `[:soil_water_content => "Soil",]`. Note that "Soil" is given as a scalar,
which means that `:soil_water_content` will be a scalar value taken from the unique "Soil" node in the plant graph.
"""
struct SingleNodeMapping <: AbstractNodeMapping
    scale::String
end

"""
    SelfNodeMapping()

Type for the self node mapping, *i.e.* a node that maps onto itself.
This is used to flag variables that will be referenced as a scalar value by other models. It can happen in two conditions:
    - the variable is computed by another scale, so we need this variable to exist as an input to this scale (it is not 
    computed at this scale otherwise)
    - the variable is an used as input to another scale but as a single value (scalar), so we need to reference it as a scalar.
"""
struct SelfNodeMapping <: AbstractNodeMapping end

"""
    MultiNodeMapping(scale)

Type for the multiple node mapping, *e.g.* `[:carbon_assimilation => ["Leaf"],]`. Note that "Leaf" is given as a vector,
which means `:carbon_assimilation` will be a vector of values taken from each "Leaf" in the plant graph.
"""
struct MultiNodeMapping <: AbstractNodeMapping
    scale::Vector{String}
end

MultiNodeMapping(scale::String) = MultiNodeMapping([scale])

"""
    MappedVar(source_organ, variable, source_variable, source_default)

A variable mapped to another scale.

# Arguments

- `source_organ`: the organ(s) that are targeted by the mapping
- `variable`: the name of the variable that is mapped
- `source_variable`: the name of the variable from the source organ (the one that computes the variable)
- `source_default`: the default value of the variable

# Examples

```jldoctest
julia> using PlantSimEngine
```

```jldoctest
julia> PlantSimEngine.MappedVar(PlantSimEngine.SingleNodeMapping("Leaf"), :carbon_assimilation, :carbon_assimilation, 1.0)
PlantSimEngine.MappedVar{PlantSimEngine.SingleNodeMapping, Symbol, Float64}(PlantSimEngine.SingleNodeMapping("Leaf"), :carbon_assimilation, :carbon_assimilation, 1.0)
```
"""
struct MappedVar{O<:AbstractNodeMapping,V<:Union{S,Vector{S}} where {S<:Symbol},T}
    source_organ::O
    variable::Symbol
    source_variable::V
    source_default::T
end

mapped_variable(m::MappedVar) = m.variable
source_organs(m::MappedVar) = m.source_organ
source_organs(m::MappedVar{O,V,T}) where {O<:AbstractNodeMapping,V,T} = nothing
mapped_organ(m::MappedVar{O,V,T}) where {O,V,T} = source_organs(m).scale
mapped_organ(m::MappedVar{O,V,T}) where {O<:SelfNodeMapping,V,T} = nothing
mapped_organ_type(m::MappedVar{O,V,T}) where {O<:AbstractNodeMapping,V,T} = O
source_variable(m::MappedVar) = m.source_variable
function source_variable(m::MappedVar{O,V,T}, organ) where {O<:SingleNodeMapping,V<:Symbol,T}
    @assert organ == mapped_organ(m) "Organ $organ not found in the mapping of the variable $(mapped_variable(m))."
    m.source_variable
end

function source_variable(m::MappedVar{O,V,T}, organ) where {O<:MultiNodeMapping,V<:Vector{Symbol},T}
    @assert organ in mapped_organ(m) "Organ $organ not found in the mapping of the variable $(mapped_variable(m))."
    m.source_variable[findfirst(o -> o == organ, mapped_organ(m))]
end

mapped_default(m::MappedVar) = m.source_default
mapped_default(m::MappedVar{O,V,T}, organ) where {O<:MultiNodeMapping,V<:Vector{Symbol},T} = m.source_default[findfirst(o -> o == organ, mapped_organ(m))]
mapped_default(m) = m # For any variable that is not a MappedVar, we return it as is