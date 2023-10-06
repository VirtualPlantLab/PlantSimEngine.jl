"""
    run!(object, meteo, constants, extra=nothing; check=true, executor=Floops.ThreadedEx())

Run the simulation for each model in the model list in the correct order, *i.e.* respecting
the dependency graph.

If several time-steps are given, the models are run sequentially for each time-step.

# Arguments

- `object`: a [`ModelList`](@ref), an array or dict of `ModelList`, or an MTG.
- `meteo`: a [`PlantMeteo.TimeStepTable`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.TimeStepTable) of 
[`PlantMeteo.Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.Atmosphere) or a single `PlantMeteo.Atmosphere`.
- `constants`: a [`PlantMeteo.Constants`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.Constants) object, or a `NamedTuple` of constant keys and values.
- `extra`: extra parameters.
- `check`: if `true`, check the validity of the model list before running the simulation (takes a little bit of time), and return more information while running.
- `executor`: the [`Floops`](https://juliafolds.github.io/FLoops.jl/stable/) executor used to run the simulation either in sequential (`executor=SequentialEx()`), in a 
multi-threaded way (`executor=ThreadedEx()`, the default), or in a distributed way (`executor=DistributedEx()`).

# Returns 

Modifies the status of the object in-place. Users may retrieve the results from the object using 
the [`status`](https://virtualplantlab.github.io/PlantSimEngine.jl/stable/API/#PlantSimEngine.status-Tuple{Any}) 
function (see examples).

# Details 

## Model execution 

The models are run according to the dependency graph. If a model has a soft dependency on another
model (*i.e.* its inputs are computed by another model), the other model is run first. If a model
has several soft dependencies, the parents (the soft dependencies) are always computed first.

## Parallel execution

Users can ask for parallel execution by providing a compatible executor to the `executor` argument. The package will also automatically
check if the execution can be parallelized. If it is not the case and the user asked for a parallel computation, it return a warning and run the simulation sequentially.
We use the [`Floops`](https://juliafolds.github.io/FLoops.jl/stable/) package to run the simulation in parallel. That means that you can provide any compatible executor to the `executor` argument.
You can take a look at [FoldsThreads.jl](https://github.com/JuliaFolds/FoldsThreads.jl) for extra thread-based executors, [FoldsDagger.jl](https://github.com/JuliaFolds/FoldsDagger.jl) for 
Transducers.jl-compatible parallel fold implemented using the Dagger.jl framework, and soon [FoldsCUDA.jl](https://github.com/JuliaFolds/FoldsCUDA.jl) for GPU computations 
(see [this issue](https://github.com/VirtualPlantLab/PlantSimEngine.jl/issues/22)) and [FoldsKernelAbstractions.jl](https://github.com/JuliaFolds/FoldsKernelAbstractions.jl). You can also take a look at 
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

    obj_parallelizable = all([object_parallelizable(dep(obj)) for obj in collect(values(object))])
    # Check if the simulation can be parallelized over objects:
    if !obj_parallelizable && executor != SequentialEx()
        is_obj_parallel = Set{AbstractModel}()
        for obj_par in [which_object_parallelizable(dep(obj)) for obj in collect(values(object))]
            for mod in obj_par[findall(x -> x.second.second == false, obj_par)]
                push!(is_obj_parallel, mod.second.first)
            end
        end

        mods_not_parallel = join(is_obj_parallel, "; ")

        check && @warn string(
            "A parallel executor was provided (`executor=$(executor)`) but some models cannot be run in parallel over objects: $mods_not_parallel. ",
            "The simulation will be run sequentially. Use `executor=SequentialEx()` to remove this warning."
        ) maxlog = 1
        executor_obj = SequentialEx()
    else
        executor_obj = executor
    end

    @floop executor_obj for obj in collect(values(object))
        run!(obj, meteo, constants, extra, check=check, executor=executor)
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
    run!(object, dep(object), 1, status(object, 1), meteo, constants, extra)
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
    sim_rows = Tables.rows(status(object))
    dep_graph = dep(object, length(sim_rows))

    if check && length(dep_graph.not_found) > 0
        error(
            "The following processes are missing to run the ModelList: ",
            dep_graph.not_found
        )
    end

    if !timestep_parallelizable(dep_graph)
        if executor != SequentialEx()
            is_ts_parallel = which_timestep_parallelizable(dep_graph)
            mods_not_parallel = join([i.second.first for i in is_ts_parallel[findall(x -> x.second.second == false, is_ts_parallel)]], "; ")

            check && @warn string(
                "A parallel executor was provided (`executor=$(executor)`) but some models cannot be run in parallel: $mods_not_parallel. ",
                "The simulation will be run sequentially. Use `executor=SequentialEx()` to remove this warning."
            ) maxlog = 1
        end
        # Not parallelizable over time-steps, it means some values depend on the previous value.
        # In this case we propagate the values of the variables from one time-step to the other, except for 
        # the variables the user provided for all time-steps.
        for (i, row) in enumerate(sim_rows)
            i > 1 && propagate_values!(sim_rows[i-1], row, object.vars_not_propagated)
            run!(object, dep_graph, i, row, meteo, constants, extra)
        end
    else
        @floop executor for (i, row) in enumerate(sim_rows)
            run!(object, dep_graph, i, row, meteo, constants, extra)
        end
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
    meteo_rows = Tables.rows(meteo)
    dep_graph = dep(object, length(meteo_rows))

    if check
        # Check if the meteo data and the status have the same length (or length 1)
        check_dimensions(object, meteo)

        if length(dep_graph.not_found) > 0
            error(
                "The following processes are missing to run the ModelList: ",
                dep_graph.not_found
            )
        end
    end

    if !timestep_parallelizable(dep_graph)
        if executor != SequentialEx()
            is_ts_parallel = which_timestep_parallelizable(dep_graph)
            mods_not_parallel = join([i.second.first for i in is_ts_parallel[findall(x -> x.second.second == false, is_ts_parallel)]], "; ")

            check && @warn string(
                "A parallel executor was provided (`executor=$(executor)`) but some models cannot be run in parallel: $mods_not_parallel. ",
                "The simulation will be run sequentially. Use `executor=SequentialEx()` to remove this warning."
            ) maxlog = 1
        end

        # Not parallelizable over time-steps, it means some values depend on the previous value.
        # In this case we propagate the values of the variables from one time-step to the other, except for 
        # the variables the user provided for all time-steps.
        for (i, meteo_i) in enumerate(meteo_rows)
            i > 1 && propagate_values!(object[i-1], object[i], object.vars_not_propagated)
            run!(object, dep_graph, i, object[i], meteo_i, constants, extra)
        end
    else
        # Computing time-steps in parallel:
        @floop executor for (i, meteo_i) in enumerate(meteo_rows)
            run!(object, dep_graph, i, object[i], meteo_i, constants, extra)
        end
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

    dep_graphs = [dep(obj) for obj in collect(values(object))]
    obj_parallelizable = all([object_parallelizable(graph) for graph in dep_graphs])

    # Check if the simulation can be parallelized over objects:
    if !obj_parallelizable && executor != SequentialEx()
        is_obj_parallel = Set{AbstractModel}()
        for graph in dep_graphs
            obj_par = which_object_parallelizable(graph)
            for mod in obj_par[findall(x -> x.second.second == false, obj_par)]
                push!(is_obj_parallel, mod.second.first)
            end
        end

        mods_not_parallel = join(is_obj_parallel, "; ")

        check && @warn string(
            "A parallel executor was provided (`executor=$(executor)`) but some models cannot be run in parallel over objects: $mods_not_parallel. ",
            "The simulation will be run sequentially. Use `executor=SequentialEx()` to remove this warning."
        ) maxlog = 1
        executor = SequentialEx()
    end
    # Each object:
    @floop executor for (i, obj) in enumerate(collect(values(object)))
        if check
            # Check if the meteo data and the status have the same length (or length 1)
            check_dimensions(obj, meteo)

            if length(dep_graphs[i].not_found) > 0
                error(
                    "The following processes are missing to run the ModelList: ",
                    dep_graphs[i].not_found
                )
            end
        end

        run!(obj, dep_graphs[i], 1, status(obj)[1], meteo, constants, extra)
    end
end

# 6- Compatibility with MTG:

# 6.1: if we pass an MTG and a mapping, then we use them to compute a GraphSimulation object 
# that we use with the first method in this file.
function run!(
    object::MultiScaleTreeGraph.Node,
    mapping::Dict{String,T} where {T},
    meteo=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    nsteps=nothing,
    outputs::Dict{String,Tuple{Symbol,Vararg{Symbol}}}=Dict{String,Tuple{Symbol,Vararg{Symbol}}}(),
    check=true,
    executor=ThreadedEx()
)
    isnothing(nsteps) && (nsteps = get_nsteps(meteo))

    sim = GraphSimulation(object, mapping, nsteps=nsteps, check=check, outputs=outputs)
    run!(
        sim,
        meteo,
        constants,
        extra;
        check,
        executor
    )

    return sim
end

# 6.2: if we pass a TreeAlike object (e.g. a GraphSimulation):
function run!(
    ::TreeAlike,
    ::SingletonAlike,
    object::GraphSimulation,
    meteo,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true,
    executor=ThreadedEx()
)
    models = get_models(object)
    # Run the simulation of each soft-coupled model in the dependency graph:
    # Note: hard-coupled processes handle themselves already
    @floop executor for (process_key, dependency_node) in collect(dep(object).roots)
        run!(object, dependency_node, 1, models, meteo, constants, extra, check, executor)
    end
end

# 6.2 bis, over several time-steps
function run!(
    ::TreeAlike,
    ::TableAlike,
    object::GraphSimulation,
    meteo,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true,
    executor=ThreadedEx()
)

    dep_graph = dep(object)
    models = get_models(object)

    # Note: The object is not thread safe here, because we write all meteo time-steps into the same Status (for each node)
    # This is because the number of nodes is usually higher than the number of cores anyway, so we don't gain much by parallelizing over
    # meteo time-steps in addition. This way we also reduce the memory footprint that can grow very large if we have many time-steps.
    for (i, meteo_i) in enumerate(Tables.rows(meteo))
        # In parallel over dependency root, i.e. for independant computations:
        @floop executor for (process_key, dependency_node) in collect(dep_graph.roots)
            # Note: parallelization over objects is handled by the run! method below
            run!(object, dependency_node, i, models, meteo_i, constants, extra, check, executor)
        end
        # At the end of the time-step, we save the results of the simulation in the object:
        save_results!(object, i)
    end
end

#! Actual calls to the model:
# Running the simulation on the dependency graph (always one time-step, one object):
function run!(object::T, dep_graph::DependencyGraph{Dict{Symbol,N}}, i, st, meteo, constants, extra; executor=ThreadedEx()) where {
    T<:ModelList,
    N<:Union{HardDependencyNode,SoftDependencyNode}
}
    # Run the simulation of each soft-coupled model in the dependency graph:
    # Note: hard-coupled processes handle themselves already
    @floop executor for (process, node) in collect(dep_graph.roots)
        run!(object, node, i, st, meteo, constants, extra)
    end
end

# for each dependency node in the graph (always one time-step, one object), actual workhorse:
function run!(
    object::T,
    node::SoftDependencyNode,
    i, # time-step to index into the dependency node (to know if the model has been called already)
    st,
    meteo,
    constants,
    extra
) where {T<:ModelList}

    # Check if all the parents have been called before the child:
    if !AbstractTrees.isroot(node) && any([p.simulation_id[i] <= node.simulation_id[i] for p in node.parent])
        # If not, this node should be called via another parent
        return nothing
    end

    # Actual call to the model:
    run!(node.value, object.models, st, meteo, constants, extra)
    node.simulation_id[i] += 1 # increment the simulation id, to know if the model has been called already

    # Recursively visit the children (soft dependencies only, hard dependencies are handled by the model itself):
    for child in node.children
        #! check if we can run this safely in a @floop loop. I would say no, 
        #! because we are running a parallel computation above already, modifying the node.simulation_id,
        #! which is not thread-safe.
        run!(object, child, i, st, meteo, constants, extra)
    end
end

# For a tree-alike object:
function run!(
    object::T,
    node::SoftDependencyNode,
    i, # time-step to index into the dependency node (to know if the model has been called already)
    models,
    meteo,
    constants,
    extra,
    check,
    executor
) where {T<:GraphSimulation} # T is the status of each node by organ type

    # run!(status(object), dependency_node, meteo, constants, extra)
    # Check if all the parents have been called before the child:
    if !AbstractTrees.isroot(node) && any([p.simulation_id[1] <= node.simulation_id[1] for p in node.parent])
        # If not, this node should be called via another parent
        return nothing
    end

    node_statuses = status(object)[node.scale] # Get the status of the nodes at the current scale
    models_at_scale = models[node.scale]

    # Check if the simulation can be parallelized over objects:
    #TODO: move this check up in the call stack so we check only once per time-step
    if !last(object_parallelizable(node)) && executor != SequentialEx()
        check && @warn string(
            "A parallel executor was provided (`executor=$(executor)`) but the model $(node.value) (or its hard dependencies) cannot be run in parallel over objects.",
            " The simulation will be run sequentially. Use `executor=SequentialEx()` to remove this warning."
        ) maxlog = 1
        executor = SequentialEx()
    end

    @floop executor for st in node_statuses # for each node status at the current scale (potentially in parallel over nodes)
        # Actual call to the model:
        run!(node.value, models_at_scale, st, meteo, constants, extra)

        #TODO: keep track of the outputs users need here.
    end

    node.simulation_id[1] += 1 # increment the simulation id, to remember that the model has been called already

    # Recursively visit the children (soft dependencies only, hard dependencies are handled by the model itself):
    for child in node.children
        #! check if we can run this safely in a @floop loop. I would say no, 
        #! because we are running a parallel computation above already, modifying the node.simulation_id,
        #! which is not thread-safe yet.
        run!(object, child, i, models, meteo, constants, extra, check, executor)
    end
end