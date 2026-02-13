"""
    get_models(m)

Get the models of a dictionary of model mapping.

# Arguments

- `m`: a scale mapping entry (for example one value from a [`ModelMapping`](@ref))

Returns a vector of models

# Examples

```jldoctest mylabel
julia> using PlantSimEngine;
```

Import example models (can be found in the `examples` folder of the package, or in the `Examples` sub-modules): 

```jldoctest mylabel
julia> using PlantSimEngine.Examples;
```

If we just give a MultiScaleModel, we get its model as a one-element vector:

```jldoctest mylabel
julia> models = MultiScaleModel( \
            model=ToyCAllocationModel(), \
            mapped_variables=[ \
                :carbon_assimilation => ["Leaf"], \
                :carbon_demand => ["Leaf", "Internode"], \
                :carbon_allocation => ["Leaf", "Internode"] \
            ], \
        );
```

```jldoctest mylabel
julia> PlantSimEngine.get_models(models)
1-element Vector{ToyCAllocationModel}:
 ToyCAllocationModel()
```

If we give a tuple of models, we get each model in a vector:

```jldoctest mylabel
julia> models2 = (  \
        MultiScaleModel( \
            model=ToyAssimModel(), \
            mapped_variables=[:soil_water_content => "Soil",], \
        ), \
        ToyCDemandModel(optimal_biomass=10.0, development_duration=200.0), \
        Status(aPPFD=1300.0, TT=10.0), \
    );
```

Notice that we provide "Soil", not ["Soil"] in the mapping because a single value is expected for the mapping here.

```jldoctest mylabel
julia> PlantSimEngine.get_models(models2)
2-element Vector{AbstractModel}:
 ToyAssimModel{Float64}(0.2)
 ToyCDemandModel{Float64}(10.0, 200.0)
```
"""
get_models(m) = [model_(i) for i in m if !isa(i, Status)]

"""
    get_model_specs(m)

Normalize model declarations to `ModelSpec`.
Plain models and `MultiScaleModel` entries are converted to `ModelSpec`.
"""
get_model_specs(m::ModelSpec) = [m]
get_model_specs(m::AbstractModel) = [as_model_spec(m)]
get_model_specs(m::MultiScaleModel) = [as_model_spec(m)]
get_model_specs(m) = [as_model_spec(i) for i in m if !isa(i, Status)]

"""
    parse_model_specs(m)

Return a process-indexed dictionary of normalized `ModelSpec`.
"""
parse_model_specs(m) = Dict{Symbol,ModelSpec}(process(model_(spec)) => spec for spec in get_model_specs(m))


# Same, for the status (if any provided):

"""
    get_status(m)

Get the status of a dictionary of model mapping.

# Arguments

- `m`: a scale mapping entry (for example one value from a [`ModelMapping`](@ref))

Returns a [`Status`](@ref) or `nothing`.

# Examples

See [`get_models`](@ref) for examples.
"""
function get_status(m)
    st = Status[i for i in m if isa(i, Status)]
    @assert length(st) <= 1 "Only one status can be provided for each organ type."
    length(st) == 0 && return nothing
    return first(st)
end

"""
    get_mapped_variables(m)

Get the mapping of a dictionary of model mapping.

# Arguments

- `m`: a scale mapping entry (for example one value from a [`ModelMapping`](@ref))

Returns a vector of pairs of symbols and strings or vectors of strings

# Examples

See [`get_models`](@ref) for examples.
"""
function get_mapped_variables(m)
    mod_mapping = [get_mapped_variables(i) for i in m if !isa(i, Status)]
    if length(mod_mapping) == 0
        return Pair{Symbol,String}[]
    end
    return reduce(vcat, mod_mapping) |> unique
end
