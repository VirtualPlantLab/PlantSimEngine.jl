"""
    run!(object, meteo, constants, extra=nothing; check=true, executor=Floops.ThreadedEx())
    run!(object, mapping, meteo, constants, extra; nsteps, outputs, check, executor)

Run the simulation for each model in the model list in the correct order, *i.e.* respecting
the dependency graph.

If several time-steps are given, the models are run sequentially for each time-step.

# Arguments

- `object`: a [`ModelList`](@ref), an array or dict of `ModelList`, or a plant graph (MTG).
- `meteo`: a [`PlantMeteo.TimeStepTable`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.TimeStepTable) of 
[`PlantMeteo.Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.Atmosphere) or a single `PlantMeteo.Atmosphere`.
- `constants`: a [`PlantMeteo.Constants`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.Constants) object, or a `NamedTuple` of constant keys and values.
- `extra`: extra parameters, not available for simulation of plant graphs (the simulation object is passed using this).
- `check`: if `true`, check the validity of the model list before running the simulation (takes a little bit of time), and return more information while running.
- `executor`: the [`Floops`](https://juliafolds.github.io/FLoops.jl/stable/) executor used to run the simulation either in sequential (`executor=SequentialEx()`), in a 
multi-threaded way (`executor=ThreadedEx()`, the default), or in a distributed way (`executor=DistributedEx()`).
- `mapping`: a mapping between the MTG and the model list.
- `nsteps`: the number of time-steps to run, only needed if no meteo is given (else it is infered from it).
- `outputs`: the outputs to get in dynamic for each node type of the MTG.

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

Load the dummy models given as example in the `Examples` sub-module:

```jldoctest run
julia> using PlantSimEngine.Examples;
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

function run!(
    object::C,
    meteo::A,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true,
    executor=ThreadedEx()
) where {eltype(C)<: ModelList, A<:Atmosphere}
    # TODO iterate over C
    return nothing
end
# Managing one or several objects, one or several time-steps:
function run!(
    object::T,
    meteo::A,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true,
    executor=ThreadedEx()
) where {T<: ModelList, A<:Atmosphere}
    
    meteo_adjusted = repeat([meteo], length(status(object)))
    run!(object, Weather([meteo]), constants; extra, check, executor)
end

#=# 2- one object, one time-step
function run!(
    object,
    meteo=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true
)
    run_node!(object, dep(object), 1, status(object, 1), meteo, constants, extra)
end=#

# one object, several meteo time-step, several status time-steps
# User entry-point
function run!(
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
        #check_dimensions(object, meteo)

        length(st) != length(Tables.rows(weather)) &&
        throw(DimensionMismatch("Component status should have the same number of time-steps ($(length(st))) than weather data ($(length(weather)))."))
        
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
        
        roots = collect(dep_graph.roots)

        for (i, meteo_i) in enumerate(meteo_rows)
            st = object[i]

            i > 1 && propagate_values!(object[i-1], object[i], object.vars_not_propagated)
            
            for (process, node) in roots
                run_node!(object, node, i, st, meteo_i, constants, extra)
            end
        end
    else
        # compute this once
        roots = collect(dep_graph.roots)
        
        # Computing time-steps in parallel:
        #@floop executor 
        for (i, meteo_i) in enumerate(meteo_rows)
            st = object[i]
            #run!(object, dep_graph, i, object[i], meteo_i, constants, extra)
            #@floop executor 
            for (process, node) in roots
                run_node!(object, node, i, st, meteo_i, constants, extra)
            end
        end
    end
end

# for each dependency node in the graph (always one time-step, one object), actual workhorse:
function run_node!(
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
        run_node!(object, child, i, st, meteo, constants, extra)
    end
end









































# Multiscale run!

# 6.1: if we pass an MTG and a mapping, then we use them to compute a GraphSimulation object 
# that we use with the first method in this file.
function run!(
    object::MultiScaleTreeGraph.Node,
    mapping::Dict{String,T} where {T},
    meteo=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    nsteps=nothing,
    outputs=nothing,
    check=true,
    executor=ThreadedEx()
)
    isnothing(nsteps) && (nsteps = get_nsteps(meteo))

    sim = GraphSimulation(object, mapping, nsteps=nsteps, check=check, outputs=outputs)
    run_graphsim!(
        sim,
        meteo,
        constants,
        extra;
        check=check,
        executor=executor
    )

    return sim
end

function run_graphsim!(
    object::GraphSimulation,
    meteo,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    check=true,
    executor=ThreadedEx()
)

    dep_graph = dep(object)
    models = get_models(object)
    # st = status(object)

    !isnothing(extra) && error("Extra parameters are not allowed for the simulation of an MTG (already used for statuses).")

    # Note: The object is not thread safe here, because we write all meteo time-steps into the same Status (for each node)
    # This is because the number of nodes is usually higher than the number of cores anyway, so we don't gain much by parallelizing over
    # meteo time-steps in addition. This way we also reduce the memory footprint that can grow very large if we have many time-steps.
    for (i, meteo_i) in enumerate(Tables.rows(meteo))
        # In parallel over dependency root, i.e. for independant computations:
        #@floop executor 
        for (process_key, dependency_node) in collect(dep_graph.roots)
            # Note: parallelization over objects is handled by the run! method below
            run_node_multiscale!(object, dependency_node, i, models, meteo_i, constants, object, check, executor)
        end
        # At the end of the time-step, we save the results of the simulation in the object:
        save_results!(object, i)
    end
end

# For a tree-alike object:
function run_node_multiscale!(
    object::T,
    node::SoftDependencyNode,
    i, # time-step to index into the dependency node (to know if the model has been called already)
    models,
    meteo,
    constants,
    extra::T, # we pass the simulation object as extra so we can access its parameters during simulation
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

    # Models that affect the MTG can't be parallelised
    # Check if the simulation can be parallelized over objects:
    #TODO: move this check up in the call stack so we check only once per time-step
    #=
    if !last(object_parallelizable(node)) && executor != SequentialEx()
        check && @warn string(
            "A parallel executor was provided (`executor=$(executor)`) but the model $(node.value) (or its hard dependencies) cannot be run in parallel over objects.",
            " The simulation will be run sequentially. Use `executor=SequentialEx()` to remove this warning."
        ) maxlog = 1
        executor = SequentialEx()
    end=#

    #@floop executor 
    for st in node_statuses # for each node status at the current scale (potentially in parallel over nodes)
        # Actual call to the model:
        run!(node.value, models_at_scale, st, meteo, constants, extra)
    end

    node.simulation_id[1] += 1 # increment the simulation id, to remember that the model has been called already

    # Recursively visit the children (soft dependencies only, hard dependencies are handled by the model itself):
    for child in node.children
        #! check if we can run this safely in a @floop loop. I would say no, 
        #! because we are running a parallel computation above already, modifying the node.simulation_id,
        #! which is not thread-safe yet.
        run_node_multiscale!(object, child, i, models, meteo, constants, extra, check, executor)
    end
end