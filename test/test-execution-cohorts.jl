using PlantSimEngine
using Test

mutable struct ExecutionCohortTestTarget{I,S}
    object_id::I
    status::S
end

@testset "Execution cohorts preserve typed payloads and ordered membership" begin
    store = PlantSimEngine.ExecutionCohortStore()
    first = ExecutionCohortTestTarget(ObjectId(1), Status(value=1.0))
    middle = ExecutionCohortTestTarget(ObjectId(2), Status(value=2.0f0))
    last = ExecutionCohortTestTarget(ObjectId(3), Status(value=3.0))
    left = PlantSimEngine.cohort_rows!(store, :growth, [first])
    center = PlantSimEngine.cohort_rows!(store, :growth, [middle])
    right = PlantSimEngine.cohort_rows!(store, :growth, [last])

    @test left isa AbstractVector{typeof(first)}
    @test keytype(left.cohort.indices) === typeof(first.object_id)
    @test isconcretetype(fieldtype(typeof(left), :cohort))
    @test (@inferred left[1]) === first
    @test eltype(center) === typeof(middle)
    @test left.cohort === right.cohort
    @test left.cohort !== center.cohort
    @test left.store === right.store === store
    @test [target.object_id.value for rows in (left, center, right) for target in rows] == [1, 2, 3]
    @test left[1] === first
    @test center[1] === middle
    @test right[1] === last
    @test left[1].status === first.status
    @test PlantSimEngine.refvalue(left[1].status, :value) === PlantSimEngine.refvalue(first.status, :value)

    another_app = PlantSimEngine.cohort_rows!(store, :another_application, [first])
    @test another_app.cohort !== left.cohort
    @test another_app[1] === first
    @test left.indices !== right.indices
    @test Base.mightalias(left, right)
    @test !Base.mightalias(left, center)

    copied = copy(left)
    @test copied.cohort === left.cohort
    @test copied.indices !== left.indices
    empty!(copied)
    @test isempty(copied)
    @test length(left) == 1
    append!(copied, left)
    append!(copied, copied)
    @test length(copied) == 2
    @test copied[1] === copied[2] === first
end

@testset "Execution owners retain separate target contexts" begin
    store = PlantSimEngine.ExecutionCohortStore()
    status = Status(value=1.0)
    root_target = ExecutionCohortTestTarget(ObjectId(:leaf), status)
    call_target = ExecutionCohortTestTarget(ObjectId(:leaf), status)
    owner = (:controller, ObjectId(:plant), :leaf_call, :manual)
    roots = PlantSimEngine.cohort_rows!(store, :growth, [root_target])
    calls = PlantSimEngine.cohort_rows!(store, :growth, [call_target]; owner)
    @test roots.store === calls.store
    @test roots.cohort !== calls.cohort
    @test roots[1] === root_target
    @test calls[1] === call_target
    @test roots[1].status === calls[1].status
    @test PlantSimEngine.cohort_location(store, :growth, :leaf; owner).cohort === calls.cohort
    @test PlantSimEngine.cohort_location(store, :growth, :leaf).cohort === roots.cohort
    @test PlantSimEngine.remove_cohort_target!(store, :growth, :leaf)
    @test calls[1] === call_target
    @test isnothing(PlantSimEngine.cohort_location(store, :growth, :leaf))
    @test !isnothing(PlantSimEngine.cohort_location(store, :growth, :leaf; owner))
end

@testset "Cohort updates leave unaffected rows and references stable" begin
    store = PlantSimEngine.ExecutionCohortStore()
    first = ExecutionCohortTestTarget(ObjectId(10), Status(value=10.0))
    last = ExecutionCohortTestTarget(ObjectId(30), Status(value=30.0))
    rows = PlantSimEngine.cohort_rows!(store, :growth, [first, last])
    first_location = PlantSimEngine.cohort_location(store, :growth, first.object_id)
    last_location = PlantSimEngine.cohort_location(store, :growth, last.object_id)
    last_reference = PlantSimEngine.refvalue(last.status, :value)

    earlier = ExecutionCohortTestTarget(ObjectId(0), Status(value=0.0))
    insert!(rows, 1, earlier)
    @test getproperty.(rows, :object_id) == ObjectId.([0, 10, 30])
    @test PlantSimEngine.cohort_location(store, :growth, first.object_id) === first_location
    @test PlantSimEngine.cohort_location(store, :growth, last.object_id) === last_location
    @test rows[3] === last
    @test PlantSimEngine.refvalue(rows[3].status, :value) === last_reference

    replacement = ExecutionCohortTestTarget(ObjectId(10), Status(value=12.0))
    @test setindex!(rows, replacement, 2) === rows
    @test rows[2] === replacement
    @test PlantSimEngine.cohort_location(store, :growth, replacement.object_id) === first_location
    @test rows[3] === last

    deleteat!(rows, 2)
    @test getproperty.(rows, :object_id) == ObjectId.([0, 30])
    @test PlantSimEngine.remove_cohort_target!(store, :growth, ObjectId(10))
    @test isnothing(PlantSimEngine.cohort_location(store, :growth, ObjectId(10)))
    @test isnothing(rows.cohort.rows[first_location.row])
    @test !PlantSimEngine.remove_cohort_target!(store, :growth, ObjectId(10))
    insert!(rows, 2, first)
    @test PlantSimEngine.cohort_location(store, :growth, first.object_id) === first_location
    @test rows[2] === first
    @test rows[3] === last

    PlantSimEngine.reset_cohort_rows!(rows, [last, first])
    @test rows[1] === last
    @test rows[2] === first
    @test PlantSimEngine.cohort_location(store, :growth, last.object_id) === last_location
    @test PlantSimEngine.reset_cohort_rows!(rows, rows) === rows
end

@testset "A new payload schema extends the persistent store" begin
    store = PlantSimEngine.ExecutionCohortStore()
    first = ExecutionCohortTestTarget(ObjectId(:first), Status(value=1.0))
    last = ExecutionCohortTestTarget(ObjectId(:last), Status(value=3.0))
    rows = PlantSimEngine.cohort_rows!(store, :growth, [first, last])
    first_location = PlantSimEngine.cohort_location(store, :growth, first.object_id)
    last_location = PlantSimEngine.cohort_location(store, :growth, last.object_id)

    changed = ExecutionCohortTestTarget(ObjectId(:first), Status(value=1.0f0, additional=7))
    changed_rows = PlantSimEngine.cohort_rows!(store, :growth, [changed])
    @test changed_rows.cohort !== rows.cohort
    @test changed_rows[1] === changed
    @test PlantSimEngine.cohort_location(store, :growth, changed.object_id).cohort === changed_rows.cohort
    @test isnothing(rows.cohort.rows[first_location.row])
    @test_throws ArgumentError rows[1]
    @test rows[2] === last
    @test PlantSimEngine.cohort_location(store, :growth, last.object_id) === last_location
    @test length(store.cohorts) == 2

    restored = PlantSimEngine.cohort_rows!(store, :growth, [first])
    @test restored.cohort === rows.cohort
    @test restored[1] === first
    @test PlantSimEngine.cohort_location(store, :growth, first.object_id) === first_location
    @test rows[2] === last
    @test isnothing(changed_rows.cohort.rows[1])
end
