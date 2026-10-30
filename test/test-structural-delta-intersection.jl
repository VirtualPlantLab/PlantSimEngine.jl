module StructuralDeltaIntersectionChecks

using PlantSimEngine, Random, Test

const PSE = PlantSimEngine

sorted_ids(values) = PSE._sort_object_ids!(ObjectId[ObjectId(value) for value in values])
intersects(sources, dirty) = PSE._sorted_object_ids_intersect_set(sources, dirty)

@testset "structural binding intersections preserve set membership" begin
    empty_sources = ObjectId[]
    empty_dirty = Set{ObjectId}()
    singleton = sorted_ids(((:plant, :Leaf, 7),))
    @test !intersects(empty_sources, empty_dirty)
    @test !intersects(empty_sources, Set(singleton))
    @test !intersects(singleton, empty_dirty)
    @test intersects(singleton, Set(singleton))

    # The common lifecycle case has one source and thousands of unrelated
    # changed objects; the reverse case has a large Many source and few changes.
    large_sources = sorted_ids((:plant, :Leaf, index) for index in 1:4096)
    large_dirty = Set(large_sources)
    @test intersects(singleton, large_dirty)
    @test !intersects(sorted_ids(((:plant, :Leaf, 4097),)), large_dirty)
    for slot in (1, 2048, 4096)
        @test intersects(large_sources, Set(sorted_ids(((:plant, :Leaf, slot),))))
    end
    @test !intersects(large_sources, Set(sorted_ids(((:plant, :Leaf, 4097),))))

    # IDs with equal display text retain distinct typed identities in either
    # intersection direction. Sorting uses the production ObjectId ordering.
    integer_id, symbolic_id = ObjectId(1), ObjectId(Symbol("1"))
    @test !intersects([integer_id], Set((symbolic_id,)))
    @test !intersects([symbolic_id], Set((integer_id,)))
    @test intersects([integer_id], Set((integer_id, symbolic_id)))
    mixed_sources = sorted_ids((1, :other, (:plant, :Leaf, 1)))
    @test !intersects(mixed_sources, Set((symbolic_id,)))
    @test intersects(mixed_sources, Set((integer_id,)))

    rng = Xoshiro(0x6ae4b871)
    pool = ObjectId[ObjectId(index) for index in 1:32]
    append!(pool, ObjectId[ObjectId(Symbol(string(index))) for index in 1:32])
    append!(pool, sorted_ids((:plant, :Leaf, index) for index in 1:32))
    for _ in 1:128
        sources = unique!(rand(rng, pool, rand(rng, 0:length(pool))))
        PSE._sort_object_ids!(sources)
        dirty = Set(rand(rng, pool, rand(rng, 0:length(pool))))
        original_sources, original_dirty = copy(sources), copy(dirty)
        @test intersects(sources, dirty) == !isdisjoint(sources, dirty)
        @test sources == original_sources
        @test dirty == original_dirty
    end
end

function repeat_intersections!(sink, sources, dirty, repetitions)
    matches = 0
    for _ in 1:repetitions
        matches += intersects(sources, dirty)
    end
    sink[] = matches
    return nothing
end

function intersection_allocations!(sink, sources, dirty, repetitions)
    repeat_intersections!(sink, sources, dirty, repetitions)
    return @allocated repeat_intersections!(sink, sources, dirty, repetitions)
end

@testset "singular binding intersection allocation is bounded as lifecycle grows" begin
    sources = sorted_ids(((:plant, :Leaf, 0),))
    small_dirty = Set(sorted_ids((:plant, :Leaf, index) for index in 1:16))
    large_dirty = Set(sorted_ids((:plant, :Leaf, index) for index in 1:4096))
    sink = Ref(-1)
    # Warm both the helper and the measuring specialization before recording;
    # all source/set construction is outside the allocation measurement.
    intersection_allocations!(sink, sources, small_dirty, 1)
    intersection_allocations!(sink, sources, large_dirty, 1)
    small_bytes = intersection_allocations!(sink, sources, small_dirty, 128)
    large_bytes = intersection_allocations!(sink, sources, large_dirty, 128)
    @test sink[] == 0
    # Deliberately allow fixed runtime/version overhead without permitting an
    # allocation proportional to every unrelated dirty ID on each lookup.
    @test large_bytes <= small_bytes + 16_384
    @test large_bytes <= 65_536
end

end # module StructuralDeltaIntersectionChecks
