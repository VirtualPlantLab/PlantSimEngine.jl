"""
    run!(object, meteo, constants, extra=nothing; check=true)

Run the simulation for each model in the model list in the correct order, *i.e.* respecting
the dependency tree.

If several time-steps are given, the models are run sequentially for each time-step.

# Arguments

- `object`: a [`ModelList`](@ref), an array or dict of `ModelList`, or an MTG.
- `meteo`: a [`PlantMeteo.TimeStepTable`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.TimeStepTable) of 
[`PlantMeteo.Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.Atmosphere) or a single `PlantMeteo.Atmosphere`.
- `constants`: a [`PlantMeteo.Constants`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.Constants) object, or a `NamedTuple` of constant keys and values.
- `extra`: extra parameters.

# Returns 

Modifies the status of the object in-place. Users may retrieve the results from the object using 
the [`status`](https://vezy.github.io/PlantSimEngine.jl/stable/API/#PlantSimEngine.status-Tuple{Any}) 
function (see examples).

# Details 

The models are run according to the dependency tree. If a model has a soft dependency on another
model (*i.e.* its inputs are computed by another model), the other model is run first. If a model
has several soft dependencies, the parents (the soft dependencies) are always computed first.

# Example

Import the packages: 

```jldoctest run
julia> using PlantSimEngine, PlantMeteo;
```

Load the dummy models given as example in the package:

```jldoctest run
julia> include(joinpath(pkgdir(PlantSimEngine), "examples/dummy.jl"));
```

Create a model list:

```jldoctest run
julia> models = ModelList(Process1Model(1.0), Process2Model(), Process3Model(), status = (var1=1.0, var2=2.0));
```

Create meteo data:

```jldoctest run
julia> meteo = Atmosphere(T=20.0, Wind=1.0, P=101.3, Rh=0.65, Ri_PAR_f=300.0);
```

Run the simulation:

```jldoctest run
julia> run!(models, meteo);
```

Get the results:

```jldoctest run
julia> (models[:var4],models[:var6])
([12.0], [41.95])
```
"""
run!

# Managing one or several objects, one or several time-steps:

# 1- several objects and several time-steps
function run!(
    object::T,
    meteo::TimeStepTable{A},
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true
) where {T<:Union{AbstractArray,AbstractDict},A<:PlantMeteo.AbstractAtmosphere}
    dep_tree = dep(object)

    if check
        # Check if the meteo data and the status have the same length (or length 1)
        check_dimensions(object, meteo)

        if length(dep_tree.not_found) > 0
            @error string(
                "The following processes are missing to run the ModelList: ",
                dep_tree.not_found
            )
        end
    end

    # Each object:
    for obj in object
        # Computing for each time-step:
        for (i, meteo_i) in enumerate(meteo)
            run!(object, dep_tree, obj[i], meteo_i, constants, extra)
        end
    end
end

# 2- one object, one time-step
function run!(
    object::T,
    meteo::M=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true
) where {T<:ModelList{Mo,S} where {Mo,S<:Status},M<:Union{PlantMeteo.AbstractAtmosphere,PlantMeteo.TimeStepRow{At} where At<:Atmosphere,Nothing}}
    run!(object, dep(object), object.status, meteo, constants, extra)
end

# 3- one object, one meteo time-step, several status time-steps (rare case but possible)
function run!(
    object::T,
    meteo::M=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true
) where {T<:ModelList,M<:Union{PlantMeteo.AbstractAtmosphere,PlantMeteo.TimeStepRow{At} where At<:Atmosphere,Nothing}}
    dep_tree = dep(object)

    if check && length(dep_tree.not_found) > 0
        @error string(
            "The following processes are missing to run the ModelList: ",
            dep_tree.not_found
        )
    end

    for i in Tables.rows(status(object))
        run!(object, dep_tree, i, meteo, constants, extra)
    end
end

# 4- one object, several meteo time-step, several status time-steps
function run!(
    object::T,
    meteo::TimeStepTable{A},
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true
) where {T<:ModelList,A<:PlantMeteo.AbstractAtmosphere}
    dep_tree = dep(object)

    if check
        # Check if the meteo data and the status have the same length (or length 1)
        check_dimensions(object, meteo)

        if length(dep_tree.not_found) > 0
            @error string(
                "The following processes are missing to run the ModelList: ",
                dep_tree.not_found
            )
        end
    end

    # Computing for each time-step:
    for (i, meteo_i) in enumerate(meteo)
        run!(object, dep_tree, object[i], meteo_i, constants, extra)
    end
end

# 5- Compatibility with MTG:
function run!(
    mtg::MultiScaleTreeGraph.Node,
    models::Dict{String,O},
    meteo::M,
    constants=PlantMeteo.Constants()
) where {O<:ModelList,M<:Union{PlantMeteo.AbstractAtmosphere,PlantMeteo.TimeStepRow{At} where At<:Atmosphere}}
    # Define the attribute name used for the models in the nodes
    attr_name = MultiScaleTreeGraph.cache_name("PlantSimEngine models")

    # initialize the MTG nodes with the corresponding models:
    init_mtg_models!(mtg, models, attr_name=attr_name)

    MultiScaleTreeGraph.transform!(
        mtg,
        (node) -> run!(node[attr_name], meteo, constants, node),
        ignore_nothing=true
    )
end


# 6- Compatibility with MTG + Weather (TimeStepTable{Atmosphere}), compute all nodes for one time step, then move to the next time step.
function run!(
    mtg::MultiScaleTreeGraph.Node,
    models::Dict{String,M},
    meteo::TimeStepTable{A},
    constants=PlantMeteo.Constants()
) where {M<:ModelList,A<:PlantMeteo.AbstractAtmosphere}
    # Define the attribute name used for the models in the nodes
    attr_name = Symbol(MultiScaleTreeGraph.cache_name("PlantSimEngine models"))

    # Init the status for the meteo step only (with an PlantMeteo.AbstractAtmosphere)
    to_init = init_mtg_models!(mtg, models, 1, attr_name=attr_name)
    #! Here we use only one time-step for the status whatever the number of timesteps
    #! to simulate. Then we use this status for all the meteo steps (we re-initialize
    #! its values at each step). We do this to not replicate much data, but it is not
    #! the best way to do it because we don't use the nice methods from above that
    #! control the simulations for meteo / status timesteps. What we could do instead
    #! is to have a TimeSteps status for several timesteps, and then use pointers to
    #! the values in the node attributes. This we would avoid to replicate the data
    #! and we could use the fancy methods from above.

    # Pre-allocate the node attributes based on the simulated variables and number of steps:
    nsteps = length(meteo)

    MultiScaleTreeGraph.traverse!(
        mtg,
        (x -> pre_allocate_attr!(x, nsteps; attr_name=attr_name)),
    )

    # Computing for each time-steps:
    for (i, meteo_i) in enumerate(meteo)
        # Then update the initialisation each time-step.
        update_mtg_models!(mtg, i, to_init, attr_name)

        MultiScaleTreeGraph.transform!(
            mtg,
            (node) -> run!(node[attr_name], meteo_i, constants, node),
            (node) -> pull_status_one_step!(node, i, attr_name=attr_name),
            filter_fun=node -> node[attr_name] !== nothing
        )
    end
end

# 7- Non-mutating version (make a copy before the call, and return the copy):
#! removed this method because it clashes with Base.run and it's not that usefull
# function run(
#     object::O,
#     meteo::T=nothing,
#     constants=PlantMeteo.Constants(),
#     extra=nothing;
#     check=true
# ) where {O<:Union{ModelList,AbstractArray,AbstractDict},T<:Union{Nothing,PlantMeteo.AbstractAtmosphere,TimeStepTable{<:PlantMeteo.AbstractAtmosphere}}}
#     object_tmp = copy(object)
#     run!(object_tmp, meteo, constants, extra; check=check)
#     return object_tmp
# end


#! Actual call to the model:

# Running the simulation on the dependency tree (always one time-step, one object):
function run!(object::T, dep_tree::DependencyTree{Dict{Symbol,N}}, st, meteo, constants, extra) where {
    T<:ModelList,
    N<:Union{HardDependencyNode,SoftDependencyNode}
}
    # Run the simulation of each soft-coupled model in the dependency tree:
    # Note: hard-coupled processes handle themselves already
    for (process, node) in dep_tree.roots
        run!(object, node, st, meteo, constants, extra)
    end
end

# for each dependency node in the tree (always one time-step, one object), actual workhorse:
function run!(
    object::T,
    node::SoftDependencyNode,
    st,
    meteo,
    constants,
    extra
) where {T<:ModelList}

    # Check if all the parents have been called before the child:
    if !AbstractTrees.isroot(node) && any([p.simulation_id <= node.simulation_id for p in node.parent])
        # If not, this node should be called via another parent
        return nothing
    end

    # Actual call to the model:
    run!(node.value, object.models, st, meteo, constants, extra)
    node.simulation_id += 1 # increment the simulation id, to know if the model has been called already

    # Recursively visit the children (soft dependencies only, hard dependencies are handled by the model itself):
    for child in node.children
        run!(object, child, st, meteo, constants, extra)
    end
end