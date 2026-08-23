using PlantSimEngine

"""
Benchmark-only identity-aware view over an existing vector carrier.

This prototype measures the cost of carrying compiler-owned object IDs beside
the current carrier. It is deliberately not part of the public API.
"""
struct DistributedOutputBenchmarkBoundMany{T,I,V} <: AbstractVector{T}
    object_ids::I
    values::V
end

function DistributedOutputBenchmarkBoundMany(object_ids::I, values::V) where {I,V}
    length(object_ids) == length(values) || throw(
        DimensionMismatch(
            "Object IDs and values must have the same length.",
        ),
    )
    return DistributedOutputBenchmarkBoundMany{eltype(V),I,V}(
        object_ids,
        values,
    )
end

Base.IndexStyle(::Type{<:DistributedOutputBenchmarkBoundMany}) = IndexLinear()
Base.size(values::DistributedOutputBenchmarkBoundMany) = size(values.values)
Base.length(values::DistributedOutputBenchmarkBoundMany) = length(values.values)
@inline Base.getindex(values::DistributedOutputBenchmarkBoundMany, index::Int) =
    @inbounds values.values[index]

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
    object_ids = [ObjectId(Symbol(:object_, index)) for index in 1:nobjects]
    references = [Ref(Float64(index)) for index in 1:nobjects]
    ref_values = PlantSimEngine.RefVector(references)
    bound_values =
        DistributedOutputBenchmarkBoundMany(object_ids, ref_values)
    heterogeneous_values = PlantSimEngine.ObjectRefVector(
        [Ref{Any}(Float64(index)) for index in 1:nobjects],
    )

    exact_values = collect(Float64, 1:nobjects)
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
        exact_values=exact_values,
        permuted_result_ids=permuted_result_ids,
        permuted_values=permuted_values,
        result_to_destination=result_to_destination,
        exact_targets=exact_targets,
        permuted_targets=permuted_targets,
    )
end
