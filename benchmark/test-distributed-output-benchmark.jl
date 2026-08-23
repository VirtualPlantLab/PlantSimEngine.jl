using PlantSimEngine

PlantSimEngine.@process "distributed_output_benchmark_bound_input" verbose = false
PlantSimEngine.@process "distributed_output_benchmark_status_input" verbose = false
PlantSimEngine.@process "distributed_output_benchmark_scene_writer" verbose = false

struct DistributedOutputBenchmarkBoundInputModel <:
       AbstractDistributed_Output_Benchmark_Bound_InputModel end
struct DistributedOutputBenchmarkStatusInputModel <:
       AbstractDistributed_Output_Benchmark_Status_InputModel end
struct DistributedOutputBenchmarkSceneWriterModel <:
       AbstractDistributed_Output_Benchmark_Scene_WriterModel end

PlantSimEngine.inputs_(::DistributedOutputBenchmarkBoundInputModel) = (
    signals=Required(Vector{Float64}),
)
PlantSimEngine.outputs_(::DistributedOutputBenchmarkBoundInputModel) = (
    total=0.0,
)
PlantSimEngine.inputs_(::DistributedOutputBenchmarkStatusInputModel) = (
    signals=Required(Vector{Float64}),
)
PlantSimEngine.outputs_(::DistributedOutputBenchmarkStatusInputModel) = (
    total=0.0,
)
PlantSimEngine.inputs_(::DistributedOutputBenchmarkSceneWriterModel) = NamedTuple()
PlantSimEngine.outputs_(::DistributedOutputBenchmarkSceneWriterModel) = NamedTuple()
function PlantSimEngine.run!(
    ::DistributedOutputBenchmarkSceneWriterModel,
    status,
    environment,
    constants,
    context,
)
    return nothing
end

function PlantSimEngine.run!(
    ::DistributedOutputBenchmarkBoundInputModel,
    status,
    environment,
    constants,
    context,
)
    signals = bound_input(context, :signals)
    total = 0.0
    @inbounds for index in eachindex(signals)
        total += signals[index]
    end
    status.total = total
    return nothing
end

function PlantSimEngine.run!(
    ::DistributedOutputBenchmarkStatusInputModel,
    status,
    environment,
    constants,
    context,
)
    total = 0.0
    @inbounds for index in eachindex(status.signals)
        total += status.signals[index]
    end
    status.total = total
    return nothing
end

function benchmark_distributed_output_sum(values)
    total = 0.0
    @inbounds for index in eachindex(values)
        total += values[index]
    end
    return total
end

function benchmark_assign_distributed_outputs_exact!(targets, values)
    @boundscheck length(targets) == length(values) || throw(
        DimensionMismatch("Output targets and values must have the same length."),
    )
    @inbounds for index in eachindex(values)
        targets[index] = values[index]
    end
    return targets
end

function benchmark_assign_distributed_outputs_permuted!(
    targets,
    values,
    result_to_destination,
)
    @boundscheck length(result_to_destination) == length(values) || throw(
        DimensionMismatch(
            "The compiled output permutation and values must have the same length.",
        ),
    )
    @inbounds for result_index in eachindex(values)
        targets[result_to_destination[result_index]] = values[result_index]
    end
    return targets
end

"""
    compile_distributed_output_benchmark_permutation(destination_ids, result_ids)

Compile and validate the result-row to destination-position mapping used by the
benchmark. This intentionally allocating operation represents compilation or a
lifecycle barrier, never a steady-state model call.
"""
function compile_distributed_output_benchmark_permutation(
    destination_ids,
    result_ids,
)
    length(destination_ids) == length(result_ids) || throw(
        DimensionMismatch(
            "Exact output coverage requires one result per destination.",
        ),
    )
    position_by_id = Dict{eltype(destination_ids),Int}()
    sizehint!(position_by_id, length(destination_ids))
    for (position, object_id) in pairs(destination_ids)
        haskey(position_by_id, object_id) && throw(
            ArgumentError("Duplicate destination object ID `$(object_id)`."),
        )
        position_by_id[object_id] = position
    end

    result_to_destination = Vector{Int}(undef, length(result_ids))
    seen = falses(length(destination_ids))
    for (result_index, object_id) in pairs(result_ids)
        destination_index = get(position_by_id, object_id, 0)
        iszero(destination_index) && throw(
            ArgumentError("Unknown result object ID `$(object_id)`."),
        )
        seen[destination_index] && throw(
            ArgumentError("Duplicate result object ID `$(object_id)`."),
        )
        seen[destination_index] = true
        result_to_destination[result_index] = destination_index
    end
    all(seen) || throw(
        ArgumentError("Exact output coverage is missing destination object IDs."),
    )
    return result_to_destination
end

function setup_distributed_output_benchmark(nobjects::Int=1_000)
    nobjects > 0 || throw(ArgumentError("`nobjects` must be positive."))
    pairs = [
        (
            id=ObjectId(Symbol(:object_, index)),
            reference=Ref(Float64(index)),
            heterogeneous_reference=Ref{Any}(Float64(index)),
        ) for index in 1:nobjects
    ]
    sort!(pairs; by=pair -> string(pair.id.value))
    object_ids = getproperty.(pairs, :id)
    references = getproperty.(pairs, :reference)
    ref_values = PlantSimEngine.RefVector(references)
    bound_values = BoundMany(object_ids, ref_values)
    heterogeneous_values = PlantSimEngine.ObjectRefVector(
        getproperty.(pairs, :heterogeneous_reference),
    )
    bound_heterogeneous_values = BoundMany(
        object_ids,
        heterogeneous_values,
    )

    exact_values = getindex.(references)
    permuted_result_ids = reverse(object_ids)
    permuted_values = reverse(exact_values)
    result_to_destination =
        compile_distributed_output_benchmark_permutation(
            object_ids,
            permuted_result_ids,
        )
    exact_targets = PlantSimEngine.RefVector(
        [Ref(0.0) for _ in 1:nobjects],
    )
    permuted_targets = PlantSimEngine.RefVector(
        [Ref(0.0) for _ in 1:nobjects],
    )

    return (
        object_ids=object_ids,
        ref_values=ref_values,
        bound_values=bound_values,
        heterogeneous_values=heterogeneous_values,
        bound_heterogeneous_values=bound_heterogeneous_values,
        exact_values=exact_values,
        permuted_result_ids=permuted_result_ids,
        permuted_values=permuted_values,
        result_to_destination=result_to_destination,
        exact_targets=exact_targets,
        permuted_targets=permuted_targets,
    )
end

function setup_distributed_output_input_benchmark(
    nobjects::Int=1_000;
    identity_aware::Bool,
)
    nobjects > 0 || throw(ArgumentError("`nobjects` must be positive."))
    objects = Object[Object(:scene; scale=:Scene)]
    sizehint!(objects, nobjects + 1)
    for index in 1:nobjects
        push!(
            objects,
            Object(
                Symbol(:leaf_, index);
                scale=:Leaf,
                parent=:scene,
                status=Status(signal=Float64(index)),
            ),
        )
    end
    input_model = identity_aware ?
                  DistributedOutputBenchmarkBoundInputModel() :
                  DistributedOutputBenchmarkStatusInputModel()
    model = CompositeModel(
        objects...;
        applications=(
            ModelSpec(
                input_model;
                name=:input_benchmark,
                on=One(scale=:Scene),
                inputs=(
                    :signals => Many(
                        scale=:Leaf,
                        within=SceneScope(),
                        var=:signal,
                        from_status=true,
                    ),
                ),
            ),
        ),
    )
    simulation = run!(model; outputs=:none)
    return (
        simulation=simulation,
        nsteps=100,
        expected_total=sum(Float64, 1:nobjects),
    )
end

benchmark_distributed_output_input_steps(simulation, nsteps) =
    continue!(simulation; steps=nsteps)

function setup_distributed_output_compilation_benchmark(
    nobjects::Int=1_000;
    distributed::Bool,
)
    nobjects >= 0 || throw(ArgumentError("`nobjects` must be non-negative."))
    objects = Object[Object(:scene; scale=:Scene)]
    sizehint!(objects, nobjects + 1)
    for index in 1:nobjects
        push!(
            objects,
            Object(
                Symbol(:leaf_, index);
                scale=:Leaf,
                parent=:scene,
            ),
        )
    end
    application = if distributed
        ModelSpec(
            DistributedOutputBenchmarkSceneWriterModel();
            name=:scene_writer,
            on=One(scale=:Scene),
            outputs_to=(
                leaves=OutputTo(
                    Many(scale=:Leaf, within=SceneScope());
                    vars=(incident_par=Default(0.0),),
                ),
            ),
        )
    else
        ModelSpec(
            DistributedOutputBenchmarkSceneWriterModel();
            name=:scene_writer,
            on=One(scale=:Scene),
        )
    end
    return CompositeModel(objects...; applications=(application,))
end

benchmark_compile_distributed_output_model(model) =
    Advanced.compile_composite_model(model)

function setup_distributed_output_lifecycle_benchmark(nobjects::Int=1_000)
    model = setup_distributed_output_compilation_benchmark(
        nobjects;
        distributed=true,
    )
    Advanced.refresh_bindings!(model)
    return model, nobjects + 1
end

function benchmark_refresh_distributed_output_lifecycle!(model, new_index)
    object_id = Symbol(:leaf_, new_index)
    register_object!(model, Object(object_id; scale=:Leaf); parent=:scene)
    return Advanced.refresh_bindings!(model)
end

function setup_distributed_output_input_step_benchmark(
    nobjects::Int=1_000;
    identity_aware::Bool,
)
    data = setup_distributed_output_input_benchmark(
        nobjects;
        identity_aware=identity_aware,
    )
    return data.simulation, data.nsteps
end
