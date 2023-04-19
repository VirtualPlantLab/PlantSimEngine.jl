"""
    run!(object, meteo, constants, extra=nothing; check=true, executor=Floops.ThreadedEx())

Run the simulation for each model in the model list in the correct order, *i.e.* respecting
the dependency tree.

If several time-steps are given, the models are run sequentially for each time-step.

# Arguments

- `object`: a [`ModelList`](@ref), an array or dict of `ModelList`, or an MTG.
- `meteo`: a [`PlantMeteo.TimeStepTable`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.TimeStepTable) of 
[`PlantMeteo.Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.Atmosphere) or a single `PlantMeteo.Atmosphere`.
- `constants`: a [`PlantMeteo.Constants`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.Constants) object, or a `NamedTuple` of constant keys and values.
- `extra`: extra parameters.
- `check`: if `true`, check the validity of the model list before running the simulation (takes a little bit of time).
- `executor`: the [`Floops`](https://juliafolds.github.io/FLoops.jl/stable/) executor used to run the simulation either in sequential (`executor=SequentialEx()`), in a 
multi-threaded way (`executor=ThreadedEx()`, the default), or in a distributed way (`executor=DistributedEx()`).

# Returns 

Modifies the status of the object in-place. Users may retrieve the results from the object using 
the [`status`](https://vezy.github.io/PlantSimEngine.jl/stable/API/#PlantSimEngine.status-Tuple{Any}) 
function (see examples).

# Details 

## Model execution 

The models are run according to the dependency tree. If a model has a soft dependency on another
model (*i.e.* its inputs are computed by another model), the other model is run first. If a model
has several soft dependencies, the parents (the soft dependencies) are always computed first.

## Parallel execution

We use the [`Floops`](https://juliafolds.github.io/FLoops.jl/stable/) package to run the simulation in parallel. That means that you can provide any compatible executor to the `executor` argument.
You can take a look at [FoldsThreads.jl](https://github.com/JuliaFolds/FoldsThreads.jl) for extra thread-based executors, [FoldsDagger.jl](https://github.com/JuliaFolds/FoldsDagger.jl) for 
Transducers.jl-compatible parallel fold implemented using the Dagger.jl framework, and soon [FoldsCUDA.jl](https://github.com/JuliaFolds/FoldsCUDA.jl) for GPU computations 
(see [this issue](https://github.com/VEZY/PlantSimEngine.jl/issues/22)) and [FoldsKernelAbstractions.jl](https://github.com/JuliaFolds/FoldsKernelAbstractions.jl). You can also take a look at 
[ParallelMagics.jl](https://github.com/JuliaFolds/ParallelMagics.jl) to check if automatic parallelization is possible.

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

# This is the default function called by the user, which uses traits
# to dispatch to the correct method. The traits are defined in table_traits.jl
# and define either TableAlike or SingletonAlike objects. 
# Please use these traits to define your own objects.
function run!(
    object,
    meteo=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true,
    executor=ThreadedEx()
)
    run!(
        DataFormat(object),
        DataFormat(meteo),
        object,
        meteo,
        constants,
        extra;
        check,
        executor
    )
end

# 1- several objects and several time-steps
function run!(
    ::TableAlike,
    ::TableAlike,
    object::T,
    meteo::TimeStepTable{A},
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true,
    executor=ThreadedEx()
) where {T<:Union{AbstractArray,AbstractDict},A}

    # Computing for each time-step:
    @floop executor for (i, meteo_i) in collect(enumerate(meteo)), obj in collect(values(object))
        dep_tree = dep(obj)

        if check
            # Check if the meteo data and the status have the same length (or length 1)
            check_dimensions(obj, meteo)

            if length(dep_tree.not_found) > 0
                error(
                    "The following processes are missing in the ModelList: ",
                    dep_tree.not_found
                )
            end
        end
        run!(obj, dep_tree, obj[i], meteo_i, constants, extra)
    end
end

# 2- one object, one time-step
function run!(
    ::SingletonAlike,
    ::SingletonAlike,
    object,
    meteo=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true
)
    run!(object, dep(object), status(object, 1), meteo, constants, extra)
end

# 3- one object, one meteo time-step, several status time-steps (rare case but possible)
function run!(
    ::TableAlike,
    ::SingletonAlike,
    object::T,
    meteo=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true,
    executor=ThreadedEx()
) where {T<:ModelList}
    dep_tree = dep(object)

    if check && length(dep_tree.not_found) > 0
        error(
            "The following processes are missing to run the ModelList: ",
            dep_tree.not_found
        )
    end

    @floop executor for i in Tables.rows(status(object))
        run!(object, dep_tree, i, meteo, constants, extra)
    end
end

# 4- one object, several meteo time-step, several status time-steps
function run!(
    ::TableAlike,
    ::TableAlike,
    object::T,
    meteo,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true,
    executor=ThreadedEx()
) where {T<:ModelList}
    dep_tree = dep(object)

    if check
        # Check if the meteo data and the status have the same length (or length 1)
        check_dimensions(object, meteo)

        if length(dep_tree.not_found) > 0
            error(
                "The following processes are missing to run the ModelList: ",
                dep_tree.not_found
            )
        end
    end

    # Computing for each time-step:
    @floop executor for (i, meteo_i) in collect(enumerate(meteo))
        run!(object, dep_tree, object[i], meteo_i, constants, extra)
    end
end

# 5- several objects and one meteo time-step
function run!(
    ::TableAlike,
    ::SingletonAlike,
    object::T,
    meteo,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true,
    executor=ThreadedEx()
) where {T<:Union{AbstractArray,AbstractDict}}

    # Each object:
    @floop executor for obj in collect(values(object))
        dep_tree = dep(obj)

        if check
            # Check if the meteo data and the status have the same length (or length 1)
            check_dimensions(obj, meteo)

            if length(dep_tree.not_found) > 0
                error(
                    "The following processes are missing to run the ModelList: ",
                    dep_tree.not_found
                )
            end
        end

        run!(obj, dep_tree, status(obj)[1], meteo, constants, extra)
    end
end

# 6- Compatibility with MTG:
function run!(
    ::TreeAlike,
    ::TableAlike,
    mtg::MultiScaleTreeGraph.Node,
    meteo,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true,
    executor=ThreadedEx()
)

    @assert extra === nothing "The extra argument cannot be used with an MTG. It already contains the node."

    # Define the attribute name used for the models in the nodes
    attr_name = Symbol(MultiScaleTreeGraph.cache_name("PlantSimEngine models"))

    # Initialize the models and pre-allocate nodes attributes:
    # init_mtg_models!(mtg, models, length(meteo), attr_name=attr_name)

    # # Here we make a simulation for one time-step and going to the next node.
    # # This is good for models that need the result of others nodes on one time-step.
    # # but not efficient for models that are completely independent.
    # # Computing for each time-steps:
    # for (i, meteo_i) in enumerate(meteo)
    #     MultiScaleTreeGraph.transform!(
    #         mtg,
    #         (node) -> run!(node[attr_name], meteo_i, constants, node, check=check, executor=executor),
    #         filter_fun=node -> node[attr_name] !== nothing
    #     )
    # end

    MultiScaleTreeGraph.transform!(
        mtg,
        (node) -> run!(node[attr_name], meteo, constants, node, check=check, executor=executor),
        filter_fun=node -> node[attr_name] !== nothing
    )
end

# 8- Non-mutating version (make a copy before the call, and return the copy):
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
function run!(object::T, dep_tree::DependencyTree{Dict{Symbol,N}}, st, meteo, constants, extra; executor=ThreadedEx()) where {
    T<:ModelList,
    N<:Union{HardDependencyNode,SoftDependencyNode}
}
    # Run the simulation of each soft-coupled model in the dependency tree:
    # Note: hard-coupled processes handle themselves already
    @floop executor for (process, node) in collect(dep_tree.roots)
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
        #! check if we can run this safely in a @floop loop. I would say no, 
        #! because we are running a parallel computation above already, modifying the node.simulation_id,
        #! which is not thread-safe.
        run!(object, child, st, meteo, constants, extra)
    end
end