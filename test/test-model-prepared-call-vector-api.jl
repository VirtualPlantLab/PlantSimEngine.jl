module PreparedCallVectorAPIChecks

using PlantSimEngine, Random, Test
const PSE = PlantSimEngine
const Scene = getfield(parentmodule(@__MODULE__), :ColdCallSchemaActivationChecks)

ids(values) = [target.object_id for target in values]

function inspect_calls(data, simulation; prepared)
    # Capture a genuine context by running its real root kernel. No synthetic
    # context or private execution object is supplied to the public accessors.
    step!(simulation)
    root_context = data.capture[]
    @test root_context isa PSE.RunContext
    middles = call_targets(root_context, :middle)
    @test (middles.execution_batches isa Vector) == prepared
    @test length(middles) == 2
    @test size(middles) == (2,)
    @test ids(middles) == [ObjectId(:middle_a), ObjectId(:middle_b)]
    @test ids(collect(middles)) == ids(middles)
    @test middles[1].object_id == ObjectId(:middle_a)
    @test middles[2].object_id == ObjectId(:middle_b)
    @test_throws BoundsError middles[0]
    @test_throws BoundsError middles[3]
    @test_throws ArgumentError only(middles)
    @test_throws ArgumentError call_model(root_context, :middle)

    counts = copy(data.kernels)
    before = Scene.scientific_state(data.model)
    random_state = Scene.rng_probe(data.rng)
    cells = Scene.status_cells(data.model)
    buffer_id = with_call_targets(middles) do values
        @test ids(values) == [ObjectId(:middle_a), ObjectId(:middle_b)]
        first_id = objectid(values)
        reverse!(values)
        with_call_targets(middles) do nested
            @test objectid(nested) != first_id
            @test ids(nested) == [ObjectId(:middle_a), ObjectId(:middle_b)]
        end
        @test ids(values) == [ObjectId(:middle_b), ObjectId(:middle_a)]
        return first_id
    end
    with_call_targets(middles) do values
        @test objectid(values) == buffer_id
        @test ids(values) == [ObjectId(:middle_a), ObjectId(:middle_b)]
    end
    @test data.kernels == counts
    @test Scene.scientific_state(data.model) == before
    @test Scene.rng_probe(data.rng) == random_state
    Scene.assert_same_cells(data.model, cells)

    run_call!(root_context, :middle; publish=false)
    @test data.kernels == Dict(:root => 1, :middle => 2, :leaf => 2)
    # Middle records the context supplied to its actual invocation. Each leaf
    # CallTargets is a one-element prepared Vector in the activated scene.
    for name in (:middle_a, :middle_b)
        context = data.contexts[name]
        leaves = call_targets(context, :leaf)
        @test (leaves.execution_batches isa Vector) == prepared
        leaf = only(leaves)
        @test length(leaves) == 1
        @test leaf.object_id == ObjectId(name === :middle_a ? :leaf_a : :leaf_b)
        @test call_model(context, :leaf) === leaf.model
        @test leaves[1].status === leaf.status
        @test only(collect(leaves)).status === leaf.status
        with_call_targets(leaves) do values
            @test only(values).status === leaf.status
        end
        with_call_targets(leaves) do values
            @test only(values).status === leaf.status
        end
        @test !leaf.context_cache.in_use
    end
    pending = evaluate_call!(root_context, :middle)
    counts = copy(data.kernels)
    before = Scene.scientific_state(data.model)
    random_state = Scene.rng_probe(data.rng)
    accept_call!(pending)
    @test data.kernels == counts
    @test Scene.scientific_state(data.model) == before
    @test Scene.rng_probe(data.rng) == random_state
    @test_throws ArgumentError accept_call!(pending)
    return nothing
end

@testset "public prepared Vector collection APIs keep ordinary semantics" begin
    ordinary, activated = Scene.fixture(), Scene.fixture()
    schemas = Scene.observed_schemas(activated.simulation).schemas
    prepared = PSE._prepare_execution_batch_schemas(activated.simulation, schemas)
    inspect_calls(ordinary, ordinary.simulation; prepared=false)
    inspect_calls(activated, prepared; prepared=true)
    @test Scene.scientific_state(ordinary.model) == Scene.scientific_state(activated.model)
    @test Scene.rng_probe(ordinary.rng) == Scene.rng_probe(activated.rng)
    @test Scene.history(ordinary.simulation) == Scene.history(prepared)
end

@testset "empty prepared Vector preserves public count and buffer contracts" begin
    witness = Scene.fixture()
    leaf_batch_type = Scene.observed_schemas(witness.simulation).LeafB
    data = Scene.fixture(; leaves=false)
    schemas = Scene.observed_schemas(data.simulation;
        borrowed_leaf_batch=leaf_batch_type).schemas
    simulation = PSE._prepare_execution_batch_schemas(data.simulation, schemas)
    step!(simulation)
    run_call!(data.capture[], :middle; publish=false)
    @test data.kernels == Dict(:root => 1, :middle => 2, :leaf => 0)
    before = Scene.scientific_state(data.model)
    random_state = Scene.rng_probe(data.rng)
    cells = Scene.status_cells(data.model)
    for context in values(data.contexts)
        leaves = call_targets(context, :leaf)
        @test leaves.execution_batches isa Vector
        @test isempty(leaves.execution_batches)
        @test isempty(leaves)
        @test size(leaves) == (0,)
        @test iterate(leaves) === nothing
        @test isempty(collect(leaves))
        @test_throws BoundsError leaves[1]
        @test_throws ArgumentError only(leaves)
        @test_throws ArgumentError call_model(context, :leaf)
        buffer_id = with_call_targets(leaves) do targets
            @test isempty(targets)
            objectid(targets)
        end
        with_call_targets(leaves) do targets
            @test isempty(targets)
            @test objectid(targets) == buffer_id
        end
        evaluation = evaluate_call!(context, :leaf)
        @test isempty(call_targets(evaluation))
        counts = copy(data.kernels)
        accept_call!(evaluation)
        @test data.kernels == counts
        @test_throws ArgumentError accept_call!(evaluation)
    end
    @test Scene.scientific_state(data.model) == before
    @test Scene.rng_probe(data.rng) == random_state
    Scene.assert_same_cells(data.model, cells)
end

end # module PreparedCallVectorAPIChecks
