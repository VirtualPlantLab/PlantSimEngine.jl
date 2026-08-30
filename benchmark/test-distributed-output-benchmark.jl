using PlantSimEngine

PlantSimEngine.@process "distributed_output_benchmark_bound_input" verbose = false
PlantSimEngine.@process "distributed_output_benchmark_status_input" verbose = false
PlantSimEngine.@process "distributed_output_benchmark_scene_writer" verbose = false
PlantSimEngine.@process "distributed_output_benchmark_assignment" verbose = false

struct DistributedOutputBenchmarkBoundInputModel <:
       AbstractDistributed_Output_Benchmark_Bound_InputModel end
struct DistributedOutputBenchmarkStatusInputModel <:
       AbstractDistributed_Output_Benchmark_Status_InputModel end
struct DistributedOutputBenchmarkSceneWriterModel <:
       AbstractDistributed_Output_Benchmark_Scene_WriterModel end
struct DistributedOutputBenchmarkAssignmentModel{T,I,C,M} <:
       AbstractDistributed_Output_Benchmark_AssignmentModel
    table::T
    ids::I
    columns::C
    mode::M
end

function DistributedOutputBenchmarkAssignmentModel(table, mode::Symbol)
    mode in (:table, :columns, :ref_loop, :broadcast) || throw(
        ArgumentError("Unsupported assignment path `$(mode)`."),
    )
    columns = if hasproperty(table, :rank)
        (incident_par=table.incident_par, rank=table.rank)
    else
        (incident_par=table.incident_par,)
    end
    return DistributedOutputBenchmarkAssignmentModel(
        table,
        table.object_id,
        columns,
        Val(mode),
    )
end

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
PlantSimEngine.inputs_(::DistributedOutputBenchmarkAssignmentModel) = NamedTuple()
PlantSimEngine.outputs_(::DistributedOutputBenchmarkAssignmentModel) = NamedTuple()
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
    model::DistributedOutputBenchmarkAssignmentModel,
    status,
    environment,
    constants,
    context,
)
    targets = PlantSimEngine.output_targets(context, :leaves)
    benchmark_assign_outputs_api!(model.mode, targets, model)
    return nothing
end

function benchmark_assign_outputs_api!(
    ::Val{:table},
    targets,
    model::DistributedOutputBenchmarkAssignmentModel,
)
    PlantSimEngine.assign_outputs!(targets, model.table; id=:object_id)
    return nothing
end

function benchmark_assign_outputs_api!(
    ::Val{:columns},
    targets,
    model::DistributedOutputBenchmarkAssignmentModel,
)
    PlantSimEngine.assign_outputs!(targets, model.ids, model.columns)
    return nothing
end

function benchmark_assign_outputs_api!(
    ::Val{:ref_loop},
    targets,
    model::DistributedOutputBenchmarkAssignmentModel,
)
    if hasproperty(model.columns, :rank)
        benchmark_assign_distributed_output_public_columns_exact!(
            targets.columns,
            model.columns,
        )
    else
        benchmark_assign_distributed_outputs_exact!(
            targets.columns.incident_par,
            model.columns.incident_par,
        )
    end
    return nothing
end

function benchmark_assign_outputs_api!(
    ::Val{:broadcast},
    targets,
    model::DistributedOutputBenchmarkAssignmentModel,
)
    benchmark_assign_distributed_outputs_broadcast!(
        targets.columns.incident_par,
        model.columns.incident_par,
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

benchmark_distributed_output_allocations(f, args...) = @allocated f(args...)

Base.@noinline function benchmark_assign_distributed_outputs_exact!(targets, values)
    @boundscheck length(targets) == length(values) || throw(
        DimensionMismatch("Output targets and values must have the same length."),
    )
    @inbounds for index in eachindex(values)
        targets[index] = values[index]
    end
    return nothing
end

Base.@noinline function benchmark_assign_distributed_outputs_broadcast!(
    targets,
    values,
)
    targets .= values
    return nothing
end

Base.@noinline function benchmark_assign_distributed_outputs_statuses_exact!(
    statuses,
    values,
)
    @boundscheck length(statuses) == length(values) || throw(
        DimensionMismatch("Output statuses and values must have the same length."),
    )
    @inbounds for index in eachindex(values)
        statuses[index].signal = values[index]
    end
    return nothing
end

Base.@noinline function benchmark_assign_distributed_output_columns_exact!(
    targets,
    values,
)
    @boundscheck length(targets.signal) == length(values.signal) || throw(
        DimensionMismatch("Signal output targets and values must have the same length."),
    )
    @boundscheck length(targets.rank) == length(values.rank) || throw(
        DimensionMismatch("Rank output targets and values must have the same length."),
    )
    @boundscheck length(targets.signal) == length(targets.rank) || throw(
        DimensionMismatch("Output target columns must have the same length."),
    )
    @inbounds for index in eachindex(values.signal)
        targets.signal[index] = values.signal[index]
        targets.rank[index] = values.rank[index]
    end
    return nothing
end

Base.@noinline function benchmark_assign_distributed_output_public_columns_exact!(
    targets,
    values,
)
    benchmark_assign_distributed_outputs_exact!(
        targets.incident_par,
        values.incident_par,
    )
    benchmark_assign_distributed_outputs_exact!(targets.rank, values.rank)
    return nothing
end

Base.@noinline function benchmark_assign_distributed_outputs_permuted!(
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
    return nothing
end

function _compile_distributed_output_benchmark_mapping(
    destination_ids,
    result_ids,
    require_exact::Bool,
)
    require_exact && length(destination_ids) != length(result_ids) && throw(
        DimensionMismatch(
            "Exact output coverage requires one result per destination.",
        ),
    )
    length(result_ids) <= length(destination_ids) || throw(
        DimensionMismatch(
            "Output results cannot outnumber destination objects.",
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
    require_exact && !all(seen) && throw(
        ArgumentError("Exact output coverage is missing destination object IDs."),
    )
    return result_to_destination
end

"""
    compile_sparse_distributed_output_benchmark_mapping(destination_ids, result_ids)

Compile a benchmark-only sparse/random destination mapping. This helper is not
an `OutputTo` coverage policy and deliberately does not define public partial
assignment semantics; it isolates the indexed-write cost requested by the
distributed-output performance contract.
"""
compile_sparse_distributed_output_benchmark_mapping(destination_ids, result_ids) =
    _compile_distributed_output_benchmark_mapping(
        destination_ids,
        result_ids,
        false,
    )

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
    return _compile_distributed_output_benchmark_mapping(
        destination_ids,
        result_ids,
        true,
    )
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
    statuses = [Status(signal=0.0) for _ in 1:nobjects]
    status_targets = PlantSimEngine.RefVector(:signal, statuses)
    rank_values = collect(1:nobjects)
    rank_targets = PlantSimEngine.RefVector([Ref(0) for _ in 1:nobjects])
    column_targets = (signal=status_targets, rank=rank_targets)
    column_values = (signal=exact_values, rank=rank_values)
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
    sparse_result_ids = reverse(object_ids[1:10:end])
    sparse_values = reverse(exact_values[1:10:end])
    sparse_result_to_destination =
        compile_sparse_distributed_output_benchmark_mapping(
            object_ids,
            sparse_result_ids,
        )
    sparse_targets = PlantSimEngine.RefVector(
        [Ref(0.0) for _ in 1:nobjects],
    )
    heterogeneous_target_references = Any[
        if mod(index, 3) == 1
            Ref{Float32}(0.0)
        elseif mod(index, 3) == 2
            Ref{Float64}(0.0)
        else
            Ref{Real}(0.0)
        end for index in 1:nobjects
    ]
    heterogeneous_targets = PlantSimEngine.ObjectRefVector(
        heterogeneous_target_references,
    )

    return (
        object_ids=object_ids,
        ref_values=ref_values,
        bound_values=bound_values,
        heterogeneous_values=heterogeneous_values,
        bound_heterogeneous_values=bound_heterogeneous_values,
        exact_values=exact_values,
        statuses=statuses,
        status_targets=status_targets,
        column_targets=column_targets,
        column_values=column_values,
        permuted_result_ids=permuted_result_ids,
        permuted_values=permuted_values,
        result_to_destination=result_to_destination,
        exact_targets=exact_targets,
        permuted_targets=permuted_targets,
        sparse_result_ids=sparse_result_ids,
        sparse_values=sparse_values,
        sparse_result_to_destination=sparse_result_to_destination,
        sparse_targets=sparse_targets,
        heterogeneous_targets=heterogeneous_targets,
        exact_table=(object_id=object_ids, incident_par=exact_values),
        permuted_table=(
            object_id=permuted_result_ids,
            incident_par=permuted_values,
        ),
    )
end

function setup_distributed_output_mapping_refresh_benchmark(nobjects::Int=1_000)
    data = setup_distributed_output_benchmark(nobjects)
    dynamic_id = ObjectId(Symbol(:object_, nobjects + 1))
    destination_ids = [data.object_ids; dynamic_id]
    result_ids = reverse(destination_ids)
    return destination_ids, result_ids
end

benchmark_refresh_distributed_output_assignment_mapping(
    destination_ids,
    result_ids,
) = compile_distributed_output_benchmark_permutation(destination_ids, result_ids)

function setup_distributed_output_public_assignment_benchmark(
    nobjects::Int=1_000;
    order::Symbol=:exact,
    path::Symbol=:table,
    ncolumns::Int=1,
    heterogeneous::Bool=false,
)
    order in (:exact, :permuted) || throw(
        ArgumentError("Unsupported result order `$(order)`."),
    )
    ncolumns in (1, 2) || throw(
        ArgumentError("`ncolumns` must be either 1 or 2."),
    )
    heterogeneous && ncolumns != 1 && throw(
        ArgumentError("Heterogeneous targets support the one-column case."),
    )
    data = setup_distributed_output_benchmark(nobjects)
    base_table = order === :exact ? data.exact_table : data.permuted_table
    rank = order === :exact ?
           data.column_values.rank :
           reverse(data.column_values.rank)
    table = ncolumns == 1 ? base_table : (; base_table..., rank)
    output_variables = ncolumns == 1 ?
                       (incident_par=Default(0.0),) :
                       (incident_par=Default(0.0), rank=Default(0))
    objects = Object[Object(:scene; scale=:Scene)]
    sizehint!(objects, nobjects + 1)
    for (index, object_id) in enumerate(data.object_ids)
        status = if heterogeneous
            if isodd(index)
                Status(incident_par=Float32(0.0))
            else
                Status(incident_par=Float64(0.0))
            end
        else
            Status()
        end
        push!(
            objects,
            Object(
                object_id.value;
                scale=:Leaf,
                parent=:scene,
                status,
            ),
        )
    end
    model = CompositeModel(
        objects...;
        applications=(
            ModelSpec(
                DistributedOutputBenchmarkAssignmentModel(table, path);
                name=:scene_assignment,
                on=One(scale=:Scene),
                outputs_to=(
                    leaves=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=output_variables,
                    ),
                ),
            ),
        ),
    )
    simulation = run!(model; outputs=:none)
    return simulation
end

function setup_distributed_output_wide_assignment_benchmark(
    nobjects::Int=1_000;
    ncolumns::Int=7,
)
    ncolumns > 0 || throw(ArgumentError("`ncolumns` must be positive."))
    data = setup_distributed_output_benchmark(nobjects)
    names = ntuple(index -> Symbol(:output_, index), ncolumns)
    columns = NamedTuple{names}(
        ntuple(index -> fill(Float64(index), nobjects), ncolumns),
    )
    output_variables = NamedTuple{names}(
        ntuple(_ -> Default(0.0), ncolumns),
    )
    objects = Object[Object(:scene; scale=:Scene)]
    sizehint!(objects, nobjects + 1)
    for object_id in data.object_ids
        push!(
            objects,
            Object(
                object_id.value;
                scale=:Leaf,
                parent=:scene,
            ),
        )
    end
    writer = DistributedOutputBenchmarkAssignmentModel(
        nothing,
        data.object_ids,
        columns,
        Val(:columns),
    )
    model = CompositeModel(
        objects...;
        applications=(
            ModelSpec(
                writer;
                name=:scene_wide_assignment,
                on=One(scale=:Scene),
                outputs_to=(
                    leaves=OutputTo(
                        Many(scale=:Leaf, within=SceneScope());
                        vars=output_variables,
                    ),
                ),
            ),
        ),
    )
    return run!(model; outputs=:none)
end

benchmark_distributed_output_public_assignment_step(simulation) =
    continue!(simulation; steps=1)

function setup_distributed_output_assignment_control_benchmark(
    nobjects::Int=1_000,
)
    model = setup_distributed_output_compilation_benchmark(
        nobjects;
        distributed=false,
    )
    return run!(model; outputs=:none)
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
