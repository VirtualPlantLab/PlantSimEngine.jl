"""
    run!(object, meteo, constants, extra=nothing; check=true, executor=Floops.ThreadedEx())
    run!(object, mapping, meteo, constants, extra; nsteps, outputs, check, executor)

Run the simulation for each model in the model list in the correct order, *i.e.* respecting
the dependency graph.

If several time-steps are given, the models are run sequentially for each time-step.

# Arguments

- `object`: a [`ModelMapping`](@ref) for single-scale runs, or a plant graph (MTG) for multiscale runs.
- `meteo`: a [`PlantMeteo.TimeStepTable`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.TimeStepTable) of 
[`PlantMeteo.Atmosphere`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.Atmosphere) or a single `PlantMeteo.Atmosphere`.
  When meteo is provided, `duration` must be present and strictly positive.
- `constants`: a [`PlantMeteo.Constants`](https://palmstudio.github.io/PlantMeteo.jl/stable/API/#PlantMeteo.Constants) object, or a `NamedTuple` of constant keys and values.
- `extra`: extra parameters, not available for simulation of plant graphs (the simulation object is passed using this).
- `check`: if `true`, check the validity of the model list before running the simulation (takes a little bit of time), and return more information while running.
- `executor`: the [`Floops`](https://juliafolds.github.io/FLoops.jl/stable/) executor used to run the simulation either in sequential (`executor=SequentialEx()`), in a 
multi-threaded way (`executor=ThreadedEx()`, the default), or in a distributed way (`executor=DistributedEx()`).
- `mapping`: a [`ModelMapping`](@ref) between MTG scales and models.
- `nsteps`: the number of time-steps to run, only needed if no meteo is given (else it is infered from it).
- `outputs`: the outputs to get in dynamic for each node type of the MTG.
- `return_requested_outputs`: when `true` in MTG multi-rate runs, return requested resampled outputs directly
  as second return value.
- `requested_outputs_sink`: sink used to materialize requested outputs when `return_requested_outputs=true`.

# Returns 

Returns status outputs (and optionally requested exports).
For MTG multi-rate runs with `return_requested_outputs=true`, returns
`(status_outputs, requested_outputs)`.

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

Create a model mapping:

```jldoctest run
julia> mapping = ModelMapping(Process1Model(1.0), Process2Model(), Process3Model(); status = (var1=1.0, var2=2.0));
```

Create meteo data:

```jldoctest run
julia> meteo = Atmosphere(T=20.0, Wind=1.0, P=101.3, Rh=0.65, Ri_PAR_f=300.0);
```

Run the simulation:

```jldoctest run
julia> outputs_sim = run!(mapping, meteo);
```

Get the results:

```jldoctest run
julia> (outputs_sim[:var4],outputs_sim[:var6])
([12.0], [41.95])
```
"""
run!

function adjust_weather_timesteps_to_given_length(desired_length, meteo)
    # This isn't ideal in terms of codeflow, but check_dimensions will kick in later
    # And determine whether there is a status vector length discrepancy

    if DataFormat(meteo) == TableAlike()
        meteo_adjusted = TimeStepTable{Atmosphere}(meteo)
        if get_nsteps(meteo) == 1
            return Tables.rows(meteo_adjusted)[1]
        end
        return Tables.rows(meteo_adjusted)
    end

    if isnothing(meteo)
        return Weather(repeat([Atmosphere(NamedTuple())], desired_length))
    elseif get_nsteps(meteo) == 1 && desired_length > 1
        if isa(meteo, Atmosphere)
            return Weather(repeat([meteo], desired_length))
        end
    else
        return meteo # If e.g. single Atmosphere
    end
end


function _all_modellists_collection(object)
    if isa(object, AbstractArray)
        return all(x -> x isa ModelList || x isa ModelMapping{SingleScale}, object)
    elseif isa(object, AbstractDict)
        return all(x -> x isa ModelList || x isa ModelMapping{SingleScale}, values(object))
    end
    return false
end

_single_scale_runtime_object(object) = object
_single_scale_runtime_object(mapping::ModelMapping) = _modellist_from_model_mapping(mapping)

function _modellist_from_model_mapping(mapping::ModelMapping{SingleScale})
    mapping.data
end

function _modellist_from_model_mapping(::ModelMapping{MultiScale})
    error("This `ModelMapping` is a multiscale mapping. ", "Use `run!(mtg, mapping, ...)` for multiscale mappings.")
end

_modellist_from_model_mapping(mapping::ModelList) = mapping

function run!(
    mapping::M,
    meteo=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    tracked_outputs=nothing,
    check=true,
    executor=ThreadedEx(),
    return_requested_outputs=false,
    requested_outputs_sink=DataFrames.DataFrame
) where {M<:Union{ModelMapping{SingleScale},ModelList}}
    _validate_meteo_duration(meteo)
    model_list = _modellist_from_model_mapping(mapping)
    _run_modellist_singleton(
        model_list,
        meteo,
        constants,
        extra;
        tracked_outputs=tracked_outputs,
        check=check,
        executor=executor,
        return_requested_outputs=return_requested_outputs
    )
end

function run!(
    ::ModelMapping{MultiScale},
    meteo=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    tracked_outputs=nothing,
    check=true,
    executor=ThreadedEx(),
    return_requested_outputs=false,
    requested_outputs_sink=DataFrames.DataFrame
)
    error("This `ModelMapping` is a multiscale mapping. ", "Use `run!(mtg, mapping, ...)` for multiscale mappings.")
end

# User entry point, which uses traits to dispatch to the correct method. 
# The traits are defined in table_traits.jl
# and define either TableAlike, TreeAlike or SingletonAlike objects. 
function run!(
    object,
    meteo=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    tracked_outputs=nothing,
    check=true,
    executor=ThreadedEx(),
    return_requested_outputs=false,
    requested_outputs_sink=DataFrames.DataFrame
)
    _validate_meteo_duration(meteo)
    run!(
        DataFormat(object),
        object,
        meteo,
        constants,
        extra;
        tracked_outputs,
        check,
        executor,
        return_requested_outputs,
        requested_outputs_sink
    )
end

function run!(
    object::GraphSimulation,
    meteo=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    tracked_outputs=nothing,
    check=true,
    executor=ThreadedEx(),
    return_requested_outputs=false,
    requested_outputs_sink=DataFrames.DataFrame
)
    _validate_meteo_duration(meteo)
    run!(
        TreeAlike(),
        object,
        meteo,
        constants,
        extra;
        tracked_outputs=tracked_outputs,
        check=check,
        executor=executor,
        return_requested_outputs=return_requested_outputs,
        requested_outputs_sink=requested_outputs_sink,
    )
end

##########################################################################################
## ModelList (single-scale) simulations
##########################################################################################

# 1- several ModelList objects and several time-steps
function run!(
    ::TableAlike,
    object::T,
    meteo::TimeStepTable{A},
    constants=PlantMeteo.Constants(),
    extra=nothing;
    tracked_outputs=nothing,
    check=true,
    executor=ThreadedEx(),
    return_requested_outputs=false,
    requested_outputs_sink=DataFrames.DataFrame
) where {T<:Union{AbstractArray,AbstractDict},A}
    if _all_modellists_collection(object)
        Base.depwarn(
            "`run!` with a collection of `ModelList` is deprecated. Use a collection of `ModelMapping` objects instead.",
            :run!
        )
    end

    tracked_outputs isa OutputRequest && error("`OutputRequest` is only supported for MTG multi-rate simulations.")
    tracked_outputs isa AbstractVector{<:OutputRequest} && error("`OutputRequest` is only supported for MTG multi-rate simulations.")
    return_requested_outputs && error("`return_requested_outputs=true` is only supported for MTG multi-rate simulations.")

    if executor != SequentialEx()
        @warn string(
            "Parallelisation over objects was removed, (but may be reintroduced in the future). Parallelisation will only occur over timesteps."
        ) maxlog = 1
    end

    outputs_collection = isa(object, AbstractArray) ? [] : isnothing(tracked_outputs) ? Dict() : Dict{TimeStepTable{Status{typeof(tracked_outputs)}}}

    # Each object:
    for obj in object

        if isa(object, AbstractArray)
            push!(outputs_collection, run!(obj, meteo, constants, extra, tracked_outputs=tracked_outputs, check=check, executor=executor))
        else
            outputs_collection[obj.first] = run!(obj.second, meteo, constants, extra, tracked_outputs=tracked_outputs, check=check, executor=executor)
        end

    end
    return outputs_collection
end

# 2 - One object, one or multiple meteo time-step(s), with vectors provided in the status
# (meaning a single meteo timestep might be expanded to fit the status vector size)
function run!(
    ::SingletonAlike,
    object::T,
    meteo=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    tracked_outputs=nothing,
    check=true,
    executor=ThreadedEx(),
    return_requested_outputs=false,
    requested_outputs_sink=DataFrames.DataFrame
) where {T<:ModelList}
    Base.depwarn(
        "`run!(::ModelList, ...)` is deprecated. Use `run!(ModelMapping(...), ...)` instead.",
        :run!
    )
    _run_modellist_singleton(
        object,
        meteo,
        constants,
        extra;
        tracked_outputs=tracked_outputs,
        check=check,
        executor=executor,
        return_requested_outputs=return_requested_outputs
    )
end

function run!(
    ::SingletonAlike,
    object::T,
    meteo=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    tracked_outputs=nothing,
    check=true,
    executor=ThreadedEx(),
    return_requested_outputs=false,
    requested_outputs_sink=DataFrames.DataFrame
) where {T<:ModelMapping{SingleScale}}
    model_list = _modellist_from_model_mapping(object)

    _run_modellist_singleton(
        model_list,
        meteo,
        constants,
        extra;
        tracked_outputs=tracked_outputs,
        check=check,
        executor=executor,
        return_requested_outputs=return_requested_outputs
    )
end

function _run_modellist_singleton(
    object::ModelList,
    meteo=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    tracked_outputs=nothing,
    check=true,
    executor=ThreadedEx(),
    return_requested_outputs=false
)

    tracked_outputs isa OutputRequest && error("`OutputRequest` is only supported for MTG multi-rate simulations.")
    tracked_outputs isa AbstractVector{<:OutputRequest} && error("`OutputRequest` is only supported for MTG multi-rate simulations.")
    return_requested_outputs && error("`return_requested_outputs=true` is only supported for MTG multi-rate simulations.")

    meteo_adjusted = adjust_weather_timesteps_to_given_length(get_status_vector_max_length(object.status), meteo)
    nsteps = get_nsteps(meteo_adjusted)

    dep_graph = dep!(object, nsteps)

    if check
        # Check if the meteo data and the status have the same length (or length 1)
        check_dimensions(object, meteo_adjusted)

        if length(dep_graph.not_found) > 0
            error(
                "The following processes are missing to run the ModelList: ",
                dep_graph.not_found
            )
        end
    end


    if executor != SequentialEx() && nsteps > 1
        if !timestep_parallelizable(dep_graph)
            is_ts_parallel = which_timestep_parallelizable(dep_graph)
            mods_not_parallel = join([i.second.first for i in is_ts_parallel[findall(x -> x.second.second == false, is_ts_parallel)]], "; ")

            check && @warn string(
                "A parallel executor was provided (`executor=$(executor)`) but some models cannot be run in parallel: $mods_not_parallel. ",
                "The simulation will be run sequentially. Use `executor=SequentialEx()` to remove this warning."
            ) maxlog = 1
        else
            outputs_preallocated_mt = pre_allocate_outputs(object, tracked_outputs, nsteps; type_promotion=object.type_promotion, check=check)
            local vars = length(outputs_preallocated_mt) > 0 ? keys(outputs_preallocated_mt[1]) : NamedTuple()
            status_flattened_template, vector_variables_mt = flatten_status(object.status)

            # Computing time-steps in parallel:
            @floop executor for i in 1:nsteps
                @init begin
                    status_flattened = deepcopy(status_flattened_template)
                    roots = collect(dep_graph.roots)
                end
                meteo_i = meteo_adjusted[i]
                set_variables_at_timestep!(status_flattened, status(object), vector_variables_mt, i)
                for (process, node) in roots
                    run_node!(object, node, i, status_flattened, meteo_i, constants, extra)
                end
                for var in vars
                    setproperty!(outputs_preallocated_mt[i], var, status_flattened[var])
                end
            end
            return outputs_preallocated_mt
        end
    end

    outputs_preallocated = pre_allocate_outputs(object, tracked_outputs, nsteps; type_promotion=object.type_promotion, check=check)
    status_flattened, vector_variables = flatten_status(status(object))

    # Not parallelizable over time-steps, it means some values depend on the previous value.
    # In this case we propagate the values of the variables from one time-step to the other, except for 
    # the variables the user provided for all time-steps.
    roots = collect(dep_graph.roots)

    # this bit is necessary for DataFrameRow meteos, see XPalm tests
    if nsteps == 1
        for (process, node) in roots
            run_node!(object, node, 1, status_flattened, meteo_adjusted, constants, extra)
        end
        save_results!(status_flattened, outputs_preallocated, 1)
    else

        for (i, meteo_i) in enumerate(meteo_adjusted)
            for (process, node) in roots
                run_node!(object, node, i, status_flattened, meteo_i, constants, extra)
            end
            save_results!(status_flattened, outputs_preallocated, i)
            i + 1 <= nsteps && set_variables_at_timestep!(status_flattened, status(object), vector_variables, i + 1)
        end
    end

    return outputs_preallocated
end

# 3- several objects and one meteo time-step
function run!(
    ::TableAlike,
    object::T,
    meteo,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    tracked_outputs=nothing,
    check=true,
    executor=ThreadedEx(),
    return_requested_outputs=false,
    requested_outputs_sink=DataFrames.DataFrame
) where {T<:Union{AbstractArray,AbstractDict}}
    if _all_modellists_collection(object)
        Base.depwarn(
            "`run!` with a collection of `ModelList` is deprecated. Use a collection of `ModelMapping` objects instead.",
            :run!
        )
    end

    tracked_outputs isa OutputRequest && error("`OutputRequest` is only supported for MTG multi-rate simulations.")
    tracked_outputs isa AbstractVector{<:OutputRequest} && error("`OutputRequest` is only supported for MTG multi-rate simulations.")
    return_requested_outputs && error("`return_requested_outputs=true` is only supported for MTG multi-rate simulations.")
    runtime_objects = [_single_scale_runtime_object(obj) for obj in collect(values(object))]
    dep_graphs = [dep(obj) for obj in runtime_objects]
    #obj_parallelizable = all([object_parallelizable(graph) for graph in dep_graphs])

    # Check if the simulation can be parallelized over objects:
    if executor != SequentialEx()
        @warn string(
            "Parallelisation over objects was removed, (but may be reintroduced in the future). Parallelisation will only occur over timesteps."
        ) maxlog = 1
    end

    # Each object:
    for (i, obj) in enumerate(runtime_objects)

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
    end

    outputs_collection = isa(object, AbstractArray) ? [] : isnothing(tracked_outputs) ? Dict() : Dict{TimeStepTable{Status{typeof(tracked_outputs)}}}

    # Each object:
    for obj in object
        if isa(object, AbstractArray)
            push!(outputs_collection, run!(obj, meteo, constants, extra, tracked_outputs=tracked_outputs, check=check, executor=executor))
        else
            outputs_collection[obj.first] = run!(obj.second, meteo, constants, extra, tracked_outputs=tracked_outputs, check=check, executor=executor)
        end

    end
    return outputs_collection
end



# Not exposed to the user : 
# for each dependency node in the graph (always one time-step, one object), actual workhorse
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


##########################################################################################
### Multiscale simulations
##########################################################################################

# Another user entry point
# If we pass an MTG and a mapping, then we use them to compute a GraphSimulation object 
# that we then use with the generic run! entry point.
function _multirate_tracked_outputs(tracked_outputs)
    if isnothing(tracked_outputs)
        return nothing, OutputRequest[]
    elseif tracked_outputs isa OutputRequest
        return nothing, OutputRequest[tracked_outputs]
    elseif tracked_outputs isa AbstractVector{<:OutputRequest}
        return nothing, collect(tracked_outputs)
    end
    return tracked_outputs, OutputRequest[]
end

_effective_multirate(mapping::ModelMapping) = is_multirate(mapping)
_effective_multirate(sim::GraphSimulation) = is_multirate(sim)

function _active_dependency_processes(dep_graph::DependencyGraph)
    active = Set{Tuple{Symbol,Symbol}}()
    for node in traverse_dependency_graph(dep_graph, false)
        push!(active, (node.scale, node.process))
    end
    return active
end

function _runtime_clock_source_for_spec(spec::ModelSpec)
    !isnothing(timestep(spec)) && return :modelspec
    return _is_default_clock(timespec(model_(spec))) ? :meteo_base_step : :model_timespec
end

function _runtime_clock_rows(object::GraphSimulation, timeline::TimelineContext, dep_graph::DependencyGraph)
    active = _active_dependency_processes(dep_graph)
    rows = NamedTuple[]

    for (scale, specs_at_scale) in pairs(get_model_specs(object))
        for (process, spec) in pairs(specs_at_scale)
            (scale, process) in active || continue
            model = model_(spec)
            clock = _model_clock(spec, model, timeline)
            source = _runtime_clock_source_for_spec(spec)
            push!(rows, (
                scale=scale,
                process=process,
                source=source,
                clock=clock,
                model=model,
            ))
        end
    end

    return rows
end

function _validate_meteo_derived_timestep_requirements!(rows, timeline::TimelineContext)
    base_sec = timeline.base_step_seconds

    for row in rows
        row.source == :meteo_base_step || continue

        hint = _normalize_timestep_hint(row.scale, row.process, timestep_hint(row.model))
        if !isnothing(hint.fixed)
            required_sec = _seconds_from_period(hint.fixed)
            isapprox(base_sec, required_sec; atol=1.0e-9, rtol=0.0) || error(
                "Meteo timestep ($(base_sec) s) is incompatible with `timestep_hint.required=$(hint.fixed)` ",
                "for `$(row.scale)/$(row.process)` with unset `TimeStepModel(...)`. ",
                "Set an explicit `TimeStepModel(...)` or provide meteo with matching `duration`."
            )
        elseif !isnothing(hint.range)
            lo, hi = hint.range
            lo_sec = _seconds_from_period(lo)
            hi_sec = _seconds_from_period(hi)
            lo_sec <= base_sec <= hi_sec || error(
                "Meteo timestep ($(base_sec) s) is outside `timestep_hint.required=($(lo), $(hi))` ",
                "for `$(row.scale)/$(row.process)` with unset `TimeStepModel(...)`. ",
                "Set an explicit `TimeStepModel(...)` or provide meteo with compatible `duration`."
            )
        end
    end

    return nothing
end

function _warn_if_no_model_runs_at_base_timestep(rows, timeline::TimelineContext)
    isempty(rows) && return nothing
    any(isapprox(float(row.clock.dt), 1.0; atol=1.0e-9, rtol=0.0) for row in rows) && return nothing

    source_label(source) = source == :modelspec ? "ModelSpec" : (source == :model_timespec ? "timespec(model)" : "meteo")
    details = sort([
        string(
            row.scale,
            "/",
            row.process,
            "=",
            round(float(row.clock.dt) * timeline.base_step_seconds; digits=6),
            "s (",
            source_label(row.source),
            ")"
        ) for row in rows
    ])

    @warn string(
        "No model runs at the meteo base timestep (",
        timeline.base_step_seconds,
        " s). Resolved model timesteps: ",
        join(details, ", "),
        "."
    ) maxlog = 1
    return nothing
end

function run!(
    object::MultiScaleTreeGraph.Node,
    mapping::ModelMapping,
    meteo=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    nsteps=nothing,
    tracked_outputs=nothing,
    check=true,
    executor=ThreadedEx(),
    return_requested_outputs=false,
    requested_outputs_sink=DataFrames.DataFrame
)
    _validate_meteo_duration(meteo)
    effective_multirate = _effective_multirate(mapping)
    isnothing(nsteps) && (nsteps = get_nsteps(meteo))
    meteo_adjusted = if effective_multirate && meteo isa TimeStepTable{<:Atmosphere}
        # Keep TimeStepTable intact in MTG multi-rate runs so model-clock meteo
        # sampling/aggregation can use PlantMeteo sampler APIs.
        meteo
    elseif DataFormat(meteo) == TableAlike()
        nsteps == 1 ? Tables.rows(meteo)[1] : meteo
    else
        adjust_weather_timesteps_to_given_length(nsteps, meteo)
    end
    status_outputs, output_requests = _multirate_tracked_outputs(tracked_outputs)
    !effective_multirate && !isempty(output_requests) && error("`OutputRequest` requires a multirate `ModelMapping`.")
    return_requested_outputs && !effective_multirate && error("`return_requested_outputs=true` requires a multirate `ModelMapping`.")

    # NOTE : replace_mapping_status_vectors_with_generated_models is assumed to have already run if used
    # otherwise there might be vector length conflicts with timesteps
    sim = GraphSimulation(object, mapping, nsteps=nsteps, check=check, outputs=status_outputs)
    result = run!(
        sim,
        meteo_adjusted,
        constants,
        extra;
        check=check,
        executor=executor,
        tracked_outputs=output_requests,
        return_requested_outputs=return_requested_outputs,
        requested_outputs_sink=requested_outputs_sink
    )

    if return_requested_outputs
        return result
    end

    return outputs(sim)
end

function run!(
    object::MultiScaleTreeGraph.Node,
    mapping::AbstractDict{Symbol,T} where {T},
    meteo=nothing,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    nsteps=nothing,
    tracked_outputs=nothing,
    check=true,
    executor=ThreadedEx(),
    return_requested_outputs=false,
    requested_outputs_sink=DataFrames.DataFrame
)
    Base.depwarn(
        "`run!(mtg, mapping::AbstractDict, ...)` is deprecated. Use `run!(mtg, ModelMapping(mapping), ...)` or construct `ModelMapping(...)` directly.",
        :run!
    )
    run!(
        object,
        ModelMapping(mapping),
        meteo,
        constants,
        extra;
        nsteps=nsteps,
        tracked_outputs=tracked_outputs,
        check=check,
        executor=executor,
        return_requested_outputs=return_requested_outputs,
        requested_outputs_sink=requested_outputs_sink
    )
end

function run!(
    ::TreeAlike,
    object::GraphSimulation,
    meteo,
    constants=PlantMeteo.Constants(),
    extra=nothing;
    tracked_outputs=nothing,
    check=true,
    executor=ThreadedEx(),
    return_requested_outputs=false,
    requested_outputs_sink=DataFrames.DataFrame
)

    effective_multirate = _effective_multirate(object)
    dep_graph = object.dependency_graph
    models = get_models(object)
    _validate_meteo_duration(meteo)
    timeline = _timeline_context(meteo)
    meteo_sampler = effective_multirate ? _prepare_meteo_sampler(meteo) : nothing
    runtime_clock_rows = effective_multirate ? _runtime_clock_rows(object, timeline, dep_graph) : NamedTuple[]
    effective_executor = executor
    # st = status(object)
    if effective_multirate
        if executor != SequentialEx()
            @warn string(
                "Multi-rate MTG runs currently execute sequentially. ",
                "Provided `executor=$(executor)` is ignored in this mode. ",
                "Use `executor=SequentialEx()` to silence this warning."
            ) maxlog = 1
            effective_executor = SequentialEx()
        end
        _validate_meteo_derived_timestep_requirements!(runtime_clock_rows, timeline)
        _warn_if_no_model_runs_at_base_timestep(runtime_clock_rows, timeline)
        validate_canonical_publishers(object)
        prepare_output_requests!(object, tracked_outputs, timeline)
        configure_temporal_buffers!(object, timeline)
    elseif return_requested_outputs
        error("`return_requested_outputs=true` requires a multirate `ModelMapping`.")
    end

    !isnothing(extra) && error("Extra parameters are not allowed for the simulation of an MTG (already used for statuses).")

    nsteps = get_nsteps(meteo)

    # if this function is called directly with an atmosphere, don't use the Rows interface
    if nsteps == 1
        roots = collect(dep_graph.roots)
        for (process_key, dependency_node) in roots
            run_node_multiscale!(object, dependency_node, 1, models, meteo, constants, object, check, effective_executor, effective_multirate, timeline, meteo_sampler)
        end
        effective_multirate && update_requested_outputs!(object, _time_from_step(1, timeline))
        save_results!(object, 1)
    else
        for (i, meteo_i) in enumerate(Tables.rows(meteo))
            roots = collect(dep_graph.roots)
            for (process_key, dependency_node) in roots
                run_node_multiscale!(object, dependency_node, i, models, meteo_i, constants, object, check, effective_executor, effective_multirate, timeline, meteo_sampler)
            end
            effective_multirate && update_requested_outputs!(object, _time_from_step(i, timeline))
            # At the end of the time-step, we save the results of the simulation in the object:
            save_results!(object, i)
        end
    end

    # save_results! resizes the outputs melodramatically because the total # of nodes at a given scale can't always be known
    # if models create organs, so shrink it down to the final size here
    for (organ, index) in object.outputs_index
        resize!(outputs(object)[organ], index - 1)
    end

    if return_requested_outputs
        return outputs(object), collect_outputs(object; sink=requested_outputs_sink)
    end

    return outputs(object)
end


# Function that runs on dependency graph nodes, actual workhorse : 
function run_node_multiscale!(
    object::T,
    node::SoftDependencyNode,
    i, # time-step to index into the dependency node (to know if the model has been called already)
    models,
    meteo,
    constants,
    extra::T, # we pass the simulation object as extra so we can access its parameters during simulation
    check,
    executor,
    multirate,
    timeline::TimelineContext,
    meteo_sampler
) where {T<:GraphSimulation} # T is the status of each node by organ type

    # run!(status(object), dependency_node, meteo, constants, extra)
    # Check if all the parents have been called before the child:
    if !AbstractTrees.isroot(node) && any([p.simulation_id[1] <= node.simulation_id[1] for p in node.parent])
        # If not, this node should be called via another parent
        return nothing
    end

    node_statuses = status(object)[node.scale] # Get the status of the nodes at the current scale
    models_at_scale = models[node.scale]
    model_specs_at_scale = get_model_specs(object)[node.scale]
    model_spec = get(model_specs_at_scale, node.process, as_model_spec(node.value))
    model_clock = _model_clock(model_spec, node.value, timeline)
    t = _time_from_step(i, timeline)

    for st in node_statuses # for each node status at the current scale (potentially in parallel over nodes)
        should_run = !multirate || _should_run_at_time(model_clock, t)
        !should_run && continue
        if multirate
            resolve_inputs_from_temporal_state!(object, node, st, t, model_spec, timeline)
        end
        meteo_for_model = multirate ? _sample_meteo_for_model(meteo_sampler, meteo, i, model_clock, model_spec) : meteo
        # Actual call to the model:
        run!(node.value, models_at_scale, st, meteo_for_model, constants, extra)
        if multirate
            update_temporal_state_outputs!(object, node, model_spec, st, t)
        end
    end

    node.simulation_id[1] += 1 # increment the simulation id, to remember that the model has been called already

    # Recursively visit the children (soft dependencies only, hard dependencies are handled by the model itself):
    for child in node.children
        #! check if we can run this safely in a @floop loop. I would say no, 
        #! because we are running a parallel computation above already, modifying the node.simulation_id,
        #! which is not thread-safe yet.
        run_node_multiscale!(object, child, i, models, meteo, constants, extra, check, executor, multirate, timeline, meteo_sampler)
    end
end
