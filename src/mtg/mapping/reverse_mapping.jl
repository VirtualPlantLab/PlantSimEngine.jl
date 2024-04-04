"""
    reverse_mapping(mapping::Dict{String,Tuple{Any,Vararg{Any}}}; all=true)
    reverse_mapping(mapped_vars::Dict{String,Dict{Symbol,Any}})

Get the reverse mapping of a dictionary of model mapping, *i.e.* the variables that are mapped to other scales, or in other words,
what variables are given to other scales from a given scale.
This is used for *e.g.* knowing which scales are needed to add values to others.

# Arguments

- `mapping::Dict{String,Any}`: A dictionary of model mapping.
- `all::Bool`: Whether to get all the variables that are mapped to other scales, including the ones that are mapped as single values.

# Returns

A dictionary of organs (keys) with a dictionary of organs => vector of pair of variables. You can read the output as:
"for each organ (source organ), to which other organ (target organ) it is giving values for its own variables. Then for each of these source organs, which variable it is
giving to the target organ (first symbol in the pair), and to which variable it is mapping the value into the target organ (second symbol in the pair)".

# Examples

```jldoctest mylabel
julia> using PlantSimEngine
```

Import example models (can be found in the `examples` folder of the package, or in the `Examples` sub-modules): 

```jldoctest mylabel
julia> using PlantSimEngine.Examples;
```

```jldoctest mylabel
julia> mapping = Dict( \
            "Plant" => \
                MultiScaleModel( \
                    model=ToyCAllocationModel(), \
                    mapping=[ \
                        :carbon_assimilation => ["Leaf"], \
                        :carbon_demand => ["Leaf", "Internode"], \
                        :carbon_allocation => ["Leaf", "Internode"] \
                    ], \
                ), \
            "Internode" => ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), \
            "Leaf" => ( \
                MultiScaleModel( \
                    model=ToyAssimModel(), \
                    mapping=[:soil_water_content => "Soil",], \
                ), \
                ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), \
                Status(aPPFD=1300.0, TT=10.0), \
            ), \
            "Soil" => ( \
                ToySoilWaterModel(), \
            ), \
        );
```

Notice we provide "Soil", not ["Soil"] in the mapping of the `ToyAssimModel` for the `Leaf`. This is because
we expect a single value for the `soil_water_content` to be mapped here (there is only one soil). This allows 
to get the value as a singleton instead of a vector of values.

```jldoctest mylabel
julia> PlantSimEngine.reverse_mapping(mapping)
Dict{String, Dict{String, Dict{Symbol, Any}}} with 3 entries:
  "Soil"      => Dict("Leaf"=>Dict(:soil_water_content=>:soil_water_content))
  "Internode" => Dict("Plant"=>Dict(:carbon_allocation=>:carbon_allocation, :ca…
  "Leaf"      => Dict("Plant"=>Dict(:carbon_allocation=>:carbon_allocation, :ca…
```
"""
function reverse_mapping(mapping::Dict{String,T}; all=true) where {T<:Any}
    # Method for the reverse mapping applied directly on the mapping (not used in the code base)
    mapped_vars = mapped_variables(mapping, dep(mapping), verbose=false)
    reverse_mapping(mapped_vars, all=all)
end

function reverse_mapping(mapped_vars::Dict{String,Dict{Symbol,Any}}; all=true)
    reverse_multiscale_mapping = Dict{String,Dict{String,Dict{Symbol,Any}}}(org => Dict{String,Dict{Symbol,Any}}() for org in keys(mapped_vars))
    for (organ, vars) in mapped_vars # e.g.: organ = "Plant"; vars = mapped_vars[organ]
        for (var, val) in vars # e.g. var = :Rm_organs; val = vars[var]
            if isa(val, MappedVar) && !isa(val, MappedVar{SelfNodeMapping}) && (all || !isa(val, MappedVar{SingleNodeMapping}))
                # Note: We skip the MappedVar{SelfNodeMapping} because it is a special case where the variable is mapped to itself
                # and we don't want to add it to the reverse mapping. We also skip the MappedVar{SingleNodeMapping} if `all=false`
                # because we don't want to add the variables that are mapped as single values to the reverse mapping.

                mapped_orgs = mapped_organ(val)
                isnothing(mapped_orgs) && continue
                if mapped_orgs isa String
                    mapped_orgs = [mapped_orgs]
                end

                for mapped_o in mapped_orgs # e.g.: mapped_o = "Leaf"
                    # if !haskey(reverse_multiscale_mapping, mapped_o)
                    #     reverse_multiscale_mapping[mapped_o] = Dict{Symbol,Vector{MappedVar}}()
                    # end
                    if !haskey(reverse_multiscale_mapping[mapped_o], organ)
                        reverse_multiscale_mapping[mapped_o][organ] = Dict{Symbol,Any}(source_variable(val, mapped_o) => mapped_variable(val))
                    end
                    push!(reverse_multiscale_mapping[mapped_o][organ], source_variable(val, mapped_o) => mapped_variable(val))
                end
            end
        end
    end
    filter!(x -> length(last(x)) > 0, reverse_multiscale_mapping)
end