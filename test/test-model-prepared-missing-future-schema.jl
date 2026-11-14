module PreparedExecutionMissingFutureSchemaTests
using PlantSimEngine, Test
const PSE = PlantSimEngine
const Fixtures = getfield(parentmodule(@__MODULE__),:ColdCallSchemaActivationChecks)

function recorded_views(simulation, selected)
    views = PSE.ExecutionCohortRows[]
    function visit(batch)
        push!(views,batch.targets)
        for target in batch.targets, calls in target.context.calls
            batches = PSE._cached_call_execution_batches(calls)
            isnothing(batches) && continue
            for child in batches
                visit(child)
            end
        end
    end
    for group in simulation.execution_plan.groups, batch in group.batches
        visit(batch)
    end
    for batch in PSE._cached_call_execution_batches(selected)
        visit(batch)
    end
    return [(view=view,indices=copy(view.indices)) for view in views]
end

@testset "a genuine unadmitted reference family rejects before changing live cohort rows" begin
    data = Fixtures.fixture()
    schemas = Fixtures.observed_schemas(data.simulation).schemas
    simulation = PSE._prepare_execution_batch_schemas(data.simulation,schemas)
    step!(simulation)
    # Demand the real descendants whose existing rows the atomicity check saves.
    middles = call_targets(data.capture[],:middle)
    for batch in PSE._materialize_call_execution_batches!(middles), middle in batch.targets
        PSE._materialize_call_execution_batches!(call_targets(middle.context,:leaf))
    end
    cells = Fixtures.status_cells(data.model)
    science = Fixtures.scientific_state(data.model)
    random_state = Fixtures.rng_probe(data.rng)
    # An output declaration is not a supplied-reference storage constraint.
    # This is a real registered organ with a Float32 Ref, not a dummy witness.
    newborn = register_object!(data.model,Object(:leaf_bad;scale=:Leaf,
        parent=:middle_a,status=Status(visits=0,value=0f0,payload=zeros(2))))
    @test newborn.status.value isa Float32
    selected = call_targets(data.capture[],:middle;objects=(:middle_a,))
    @test selected.batch_schema isa PSE.PreparedExecutionBatchSchema
    middle = only(only(PSE._materialize_call_execution_batches!(selected)).targets)
    # Selecting Middle does not demand its Leaf Many. Reject the Float32 Ref
    # only when this test explicitly requests that descendant membership.
    leaves = call_targets(middle.context,:leaf)
    @test leaves.batch_schema isa PSE.PreparedExecutionBatchSchema
    # Parent selection is now legal. Save the cohort baseline immediately before
    # the descendant demand that must reject, including its live selected views.
    store = simulation.execution_plan.cohorts
    locations = copy(store.locations)
    payloads = Dict(key=>PSE._execution_cohort_target(location) for (key,location) in locations)
    views = recorded_views(simulation, selected)
    @test_throws "prepared execution schema" PSE._materialize_call_execution_batches!(leaves)
    @test Set(keys(store.locations)) == Set(keys(locations))
    @test all(store.locations[key] === location for (key,location) in locations)
    @test all(PSE._execution_cohort_target(store.locations[key]) === target for (key,target) in payloads)
    @test all(snapshot.view.indices == snapshot.indices for snapshot in views)
    for ((id,name),reference) in cells
        @test PSE.refvalue(model_status(data.model,id),name) === reference
    end
    @test all(NamedTuple(model_status(data.model,id)) == value for (id,value) in science)
    @test Fixtures.rng_probe(data.rng) == random_state
    @test data.kernels == Dict(:root=>1,:middle=>0,:leaf=>0)
    @test newborn.status.value === 0f0
    @test newborn.status.visits == 0
end
end
