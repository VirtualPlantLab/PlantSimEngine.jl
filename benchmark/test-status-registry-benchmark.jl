using PlantSimEngine

function setup_status_registry_benchmark(nobjects::Int)
    nobjects > 0 || throw(ArgumentError("`nobjects` must be positive."))
    statuses = [PlantSimEngine.Status(rank=index) for index in 1:nobjects]
    objects = [
        PlantSimEngine.Object(
            index;
            scale=:Leaf,
            status=statuses[index],
        ) for index in 1:nobjects
    ]
    model = PlantSimEngine.CompositeModel(objects...)
    lookup_index = cld(nobjects, 2)
    return (
        model=model,
        statuses=statuses,
        lookup_status=statuses[lookup_index],
        lookup_id=PlantSimEngine.ObjectId(lookup_index),
        expected_checksum=nobjects,
    )
end

Base.@noinline function benchmark_status_registry_lookup(model, status)
    return PlantSimEngine.object_id(model, status)
end

Base.@noinline function benchmark_status_registry_sweep_checksum(model, statuses)
    checksum = 0
    @inbounds for index in eachindex(statuses)
        checksum += PlantSimEngine.object_id(model, statuses[index]) ==
                    PlantSimEngine.ObjectId(index)
    end
    return checksum
end

function benchmark_status_registry_lookup_allocations(model, status)
    return @allocated benchmark_status_registry_lookup(model, status)
end
