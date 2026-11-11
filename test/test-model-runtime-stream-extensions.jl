module RuntimeStreamExtensionChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "stream_extension_distributor" verbose=false
PSE.@process "stream_extension_source" verbose=false
PSE.@process "stream_extension_reader" verbose=false

struct Distributor <: AbstractStream_Extension_DistributorModel
    runs::Base.RefValue{Int}
end
PSE.inputs_(::Distributor) = NamedTuple()
PSE.outputs_(::Distributor) = (a=Distributed(Default(0f0)), z=Distributed(Default(0.0)))
function PSE.run!(model::Distributor, status, environment, constants, context)
    model.runs[] += 1
    targets = output_targets(context, (:a, :z))
    for (index, id) in enumerate(object_ids(targets))
        targets.columns.a[index] = Float32(context.time) + Float32(id.value)
        targets.columns.z[index] = 10.0 * context.time + id.value
    end
    return nothing
end

struct Source <: AbstractStream_Extension_SourceModel
    runs::Base.RefValue{Int}
end
PSE.inputs_(::Source) = NamedTuple()
PSE.outputs_(::Source) = (a=0f0, z=0.0)
function PSE.run!(model::Source, status, environment, constants, context)
    model.runs[] += 1
    status.a += 1f0
    status.z += 10.0
    return nothing
end

struct Reader <: AbstractStream_Extension_ReaderModel
    runs::Base.RefValue{Int}
end
PSE.inputs_(::Reader) = (lag_a=Required(Vector{Float32}), lag_z=Required(Vector{Float64}))
PSE.outputs_(::Reader) = (seen_a=0f0, seen_z=0.0)
function PSE.run!(model::Reader, status, environment, constants, context)
    model.runs[] += 1
    status.seen_a = sum(status.lag_a; init=0f0)
    status.seen_z = sum(status.lag_z; init=0.0)
    return nothing
end

function execution_target(simulation, application, id)
    return only(target for group in simulation.execution_plan.groups
        if group.application.id === application for batch in group.batches
        for target in batch.targets if target.object_id === ObjectId(id))
end

# Copy only the owner's vector of actual stream references. The owner, source
# streams, scientific values, canonical refs and retained samples stay genuine.
function copied_sources(output::PSE.RuntimeDistributedOutputStream)
    return typeof(output)(getfield(output, :binding), copy(getfield(output, :streams)),
        getfield(output, :references), getfield(output, :dependency_horizon))
end
function copied_sources(input::PSE.RuntimeTemporalInput)
    return typeof(input)(getfield(input, :compiled), copy(getfield(input, :source_streams)))
end
histories(simulation) = Dict(key => collect(stream) for (key, stream) in outputs(simulation))

function check_append_allocations!(streams, new_streams)
    old_length = length(streams)
    @test PSE._append_validated_runtime_streams!(streams, new_streams) === streams
    resize!(streams, old_length)
    # A second warm execution keeps the real destination's capacity available.
    PSE._append_validated_runtime_streams!(streams, new_streams)
    resize!(streams, old_length)
    bytes = @allocated begin
        PSE._append_validated_runtime_streams!(streams, new_streams)
        resize!(streams, old_length)
    end
    @test bytes == 0
    return nothing
end

@testset "distributed stream extension commits only after full validation" begin
    runs = Ref(0)
    model = CompositeModel(Object(0; scale=:Scene),
        Object(1; scale=:Leaf, parent=0, status=Status(a=0f0, z=0.0));
        applications=(ModelSpec(Distributor(runs); name=:writer, on=One(id=0),
            outputs_to=(OutputTo(Many(scale=:Leaf, within=Subtree())),)),))
    simulation = run!(model; steps=1, outputs=:all)
    target = execution_target(simulation, :writer, 0)
    @test Tuple(PSE._runtime_output_variable(output) for output in target.output_bindings) == (:a, :z)
    staged = map(copied_sources, target.output_bindings)
    original_vectors = map(output -> getfield(output, :streams), staged)
    first_streams = map(first, original_vectors)
    @test all(length(streams) == 1 for streams in original_vectors)

    register_object!(model, Object(2; scale=:Leaf, parent=0, status=Status(a=0f0, z=0.0)))
    step!(simulation)
    current_target = execution_target(simulation, :writer, 0)
    @test current_target === target
    @test runs[] == 2
    @test model_status(model, 1).a === 3f0
    @test model_status(model, 2).z === 22.0
    before_history = histories(simulation)
    # Both genuine owners have staged additions, then this extra genuine entry
    # makes the final shape check fail. Neither vector may change on rejection.
    extra_entry = (staged..., first(staged))
    @test !PSE._model_execution_outputs_match(extra_entry, target.status_view, target.output_targets,
        target.context.application, target.object_id, simulation.output_retention,
        simulation.temporal_streams)
    @test all(length(streams) == 1 for streams in original_vectors)
    @test all(first(streams) === first_stream for (streams, first_stream) in
        zip(original_vectors, first_streams))

    @test PSE._model_execution_outputs_match(staged, target.status_view, target.output_targets,
        target.context.application, target.object_id, simulation.output_retention,
        simulation.temporal_streams)
    for (index, output) in enumerate(staged)
        streams = getfield(output, :streams)
        variable = PSE._runtime_output_variable(output)
        @test streams === original_vectors[index]
        @test first(streams) === first_streams[index]
        @test length(streams) == 2
        @test streams[2] === outputs(simulation)[(:writer, ObjectId(2), variable)]
    end
    # Recreate prepared descriptors after real growth without replaying kernels.
    # Their source vectors may be fresh; each binding, column and stream stays live.
    prepared = @inferred PSE._prepared_runtime_outputs(typeof(target.output_bindings),
        target.status_view, target.output_targets, target.context.application,
        target.object_id, simulation.temporal_streams, simulation.output_retention, false)
    @test typeof(prepared) === typeof(target.output_bindings)
    @test Tuple(PSE._runtime_output_variable(output) for output in prepared) == (:a, :z)
    @test first(prepared).binding === last(prepared).binding
    for (actual, original) in zip(prepared, target.output_bindings)
        @test actual.binding === original.binding
        @test actual.references === original.references
        @test length(actual.streams) == length(original.streams) == 2
        @test all(current === previous for (current, previous) in zip(actual.streams, original.streams))
    end
    @test histories(simulation) == before_history
    @test runs[] == 2
    @test outputs(simulation)[(:writer, ObjectId(2), :a)] == [(2.0, 4f0)]
    check_append_allocations!(copy(first(original_vectors)), Any[last(first(original_vectors))])
    # Heterogeneous storage keeps the same bulk-copy representation as before.
    check_append_allocations!(Any[first(first_streams)], Any[last(first(original_vectors))])
end

struct SplitDistributor <: AbstractStream_Extension_DistributorModel
    runs::Base.RefValue{Int}
end
PSE.inputs_(::SplitDistributor) = NamedTuple()
PSE.outputs_(::SplitDistributor) = (a=Distributed(Default(0f0)),
    b=Distributed(Default(0f0)), z=Distributed(Default(0.0)))
function PSE.run!(model::SplitDistributor, status, environment, constants, context)
    model.runs[] += 1
    leaves = output_targets(context, (:a, :b))
    for index in eachindex(leaves)
        leaves.columns.a[index] = Float32(context.time)
        leaves.columns.b[index] = 2f0 * Float32(context.time)
    end
    first_leaf = output_targets(context, (:z,))
    for index in eachindex(first_leaf)
        first_leaf.columns.z[index] = 10.0 * context.time
    end
    return nothing
end

function split_fixture(; split=true)
    runs = Ref(0)
    routes = split ? (
        OutputTo(Many(scale=:Leaf, within=Subtree()); vars=(:a, :b)),
        OutputTo(One(id=1, within=SceneScope()); vars=(:z,)),
    ) : (OutputTo(Many(scale=:Leaf, within=Subtree()); vars=(:a, :b, :z)),)
    model = CompositeModel(Object(0; scale=:Scene),
        Object(1; scale=:Leaf, parent=0, status=Status(a=0f0, b=0f0, z=0.0));
        applications=(ModelSpec(SplitDistributor(runs); name=:split,
            on=One(id=0), outputs_to=routes),))
    return (; model, runs, simulation=run!(model; steps=1, outputs=:all))
end

function check_reconstructed_groups(data, alignment)
    simulation = data.simulation
    target = execution_target(simulation, :split, 0)
    application = target.context.application
    before = histories(simulation)
    runs = data.runs[]
    @test PSE._model_execution_output_targets_match(target.output_targets,
        simulation.compiled, application, target.object_id)
    schema = PSE._closed_execution_cohort_schema(Tuple{typeof(target)})
    for admission in (PSE.OpenExecutionCohortSchema(), schema)
        rebuilt = PSE._new_model_execution_target(simulation.compiled,
            simulation.environment_bindings, application, target.object_id,
            simulation.temporal_streams, simulation.output_retention,
            simulation.constants; target_schema=admission)
        views = rebuilt.output_targets
        @test typeof(rebuilt) === typeof(target)
        @test keys(views) == (:a, :b, :z)
        @test views.a === views.b
        @test views.a !== views.z
        @test views.a.assignment_cache === views.b.assignment_cache
        @test (views.a.alignment_id, views.z.alignment_id) == alignment
        for variable in keys(views)
            actual, original = getproperty(views, variable), getproperty(target.output_targets, variable)
            @test actual.binding === original.binding
            @test actual.columns === original.columns
            @test collect(object_ids(actual)) == collect(object_ids(original))
        end
        for (actual, original) in zip(rebuilt.output_bindings, target.output_bindings)
            @test actual.binding === original.binding
            @test actual.references === original.references
            @test length(actual.streams) == length(original.streams)
            @test all(left === right for (left, right) in zip(actual.streams, original.streams))
        end
        @test data.runs[] == runs
        @test histories(simulation) == before
    end
    return target
end

@testset "typed output groups preserve ownership and changing destination alignment" begin
    data = split_fixture()
    original = check_reconstructed_groups(data, (1, 1))
    @test collect(object_ids(output_targets(original.context, (:a, :z)))) == [ObjectId(1)]
    a_reference = PSE.refvalue(model_status(data.model, 1), :a)

    register_object!(data.model, Object(2; scale=:Leaf, parent=0,
        status=Status(a=0f0, b=0f0, z=0.0)))
    step!(data.simulation)
    grown = check_reconstructed_groups(data, (1, 2))
    @test grown !== original
    @test_throws ArgumentError output_targets(grown.context, (:a, :z))
    @test PSE.refvalue(model_status(data.model, 1), :a) === a_reference
    @test model_status(data.model, 2).a === 2f0
    @test outputs(data.simulation)[(:split, ObjectId(2), :a)] == [(2.0, 2f0)]

    remove_object!(data.model, 2)
    step!(data.simulation)
    reduced = check_reconstructed_groups(data, (1, 1))
    @test reduced !== grown
    @test collect(object_ids(output_targets(reduced.context, (:a, :z)))) == [ObjectId(1)]
    @test PSE.refvalue(model_status(data.model, 1), :a) === a_reference
    @test outputs(data.simulation)[(:split, ObjectId(2), :a)] == [(2.0, 2f0)]
    @test data.runs[] == 3

    # Real bindings from another owner must fail even when their schema matches.
    foreign = split_fixture()
    @test !PSE._model_execution_output_targets_match(reduced.output_targets,
        foreign.simulation.compiled,
        execution_target(foreign.simulation, :split, 0).context.application, ObjectId(0))
    # A different genuine grouping is rejected before accessing its columns.
    regrouped = split_fixture(; split=false)
    @test !PSE._model_execution_output_targets_match(reduced.output_targets,
        regrouped.simulation.compiled,
        execution_target(regrouped.simulation, :split, 0).context.application, ObjectId(0))
end

@testset "prepared local outputs keep concrete owners in a distributed scene" begin
    for retention in (:none, :all)
        runs = Ref(0)
        model = CompositeModel(Object(0; scale=:Scene),
            Object(1; scale=:Leaf, parent=0, status=Status(a=0f0, z=0.0)),
            Object(2; scale=:Source, parent=0, status=Status(a=1f0, z=10.0));
            applications=(
                ModelSpec(Distributor(Ref(0)); name=:writer, on=One(id=0),
                    outputs_to=(OutputTo(Many(scale=:Leaf, within=Subtree())),)),
                ModelSpec(Source(runs); name=:source, on=One(id=2)),
            ))
        simulation = run!(model; steps=1, outputs=retention)
        target = execution_target(simulation, :source, 2)
        @test simulation.compiled.distributed_outputs isa PSE.CompiledDistributedOutputs
        @test isempty(target.output_targets)
        before = histories(simulation)
        prepared = @inferred PSE._prepared_runtime_outputs(typeof(target.output_bindings),
            target.status_view, target.output_targets, target.context.application,
            target.object_id, simulation.temporal_streams,
            simulation.output_retention, false)
        @test typeof(prepared) === typeof(target.output_bindings)
        @test PSE._model_execution_outputs_match(prepared, target.status_view,
            target.output_targets, target.context.application, target.object_id,
            simulation.output_retention, simulation.temporal_streams)
        for (actual, original) in zip(prepared, target.output_bindings)
            @test actual.stream === original.stream
            @test actual.reference === original.reference
        end
        @test histories(simulation) == before
        @test runs[] == 1
        step!(simulation)
        @test runs[] == 2
        @test model_status(model, 2).a === 3f0
        @test model_status(model, 2).z === 30.0
    end
end

@testset "temporal stream extension retains validation atomicity and live owners" begin
    source_runs, reader_runs = Ref(0), Ref(0)
    model = CompositeModel(Object(0; scale=:Scene, status=Status(lag_a=Float32[], lag_z=Float64[])),
        Object(1; scale=:Leaf, parent=0, status=Status(a=1f0, z=10.0));
        applications=(
            ModelSpec(Reader(reader_runs); name=:reader, on=One(id=0), inputs=(
                PreviousTimeStep(:lag_a) => Many(scale=:Leaf, within=Subtree(),
                    application=:source, var=:a),
                PreviousTimeStep(:lag_z) => Many(scale=:Leaf, within=Subtree(),
                    application=:source, var=:z))),
            ModelSpec(Source(source_runs); name=:source, on=Many(scale=:Leaf)),
        ))
    simulation = run!(model; steps=1, outputs=:all)
    target = execution_target(simulation, :reader, 0)
    staged = map(copied_sources, target.input_bindings)
    original_vectors = map(input -> getfield(input, :source_streams), staged)
    first_streams = map(first, original_vectors)
    @test length(staged) == 2
    @test all(length(streams) == 1 for streams in original_vectors)
    @test model_status(model, 0).seen_a === 1f0
    @test model_status(model, 0).seen_z === 10.0

    register_object!(model, Object(2; scale=:Leaf, parent=0, status=Status(a=3f0, z=30.0)))
    step!(simulation)
    current_target = execution_target(simulation, :reader, 0)
    @test current_target === target
    compiled_inputs = current_target.status_view.temporal_inputs
    @test all(getfield(input, :compiled) === compiled for (input, compiled) in zip(staged, compiled_inputs))
    @test source_runs[] == 3
    @test reader_runs[] == 2
    @test model_status(model, 0).seen_a === 5f0
    @test model_status(model, 0).seen_z === 50.0
    before_history = histories(simulation)
    # The first input is valid and stages an append; the later actual but wrong
    # compiled owner must reject before either destination vector is touched.
    wrong_owner = (first(compiled_inputs), first(compiled_inputs))
    @test !PSE._model_execution_inputs_match(staged, wrong_owner, simulation.temporal_streams)
    @test all(length(streams) == 1 for streams in original_vectors)
    @test all(first(streams) === first_stream for (streams, first_stream) in
        zip(original_vectors, first_streams))

    @test PSE._model_execution_inputs_match(staged, compiled_inputs, simulation.temporal_streams)
    for (index, input) in enumerate(staged)
        streams = getfield(input, :source_streams)
        @test streams === original_vectors[index]
        @test first(streams) === first_streams[index]
        @test length(streams) == 2
        @test streams[2] === getfield(current_target.input_bindings[index], :source_streams)[2]
    end
    @test histories(simulation) == before_history
    @test source_runs[] == 3
    @test reader_runs[] == 2
    @test outputs(simulation)[(:reader, ObjectId(0), :seen_a)] == [(1.0, 1f0), (2.0, 5f0)]
    check_append_allocations!(copy(first(original_vectors)), Any[last(first(original_vectors))])

    # The caller supplies the already-admitted current view. Local retained refs
    # still require that exact scientific owner; another real view is rejected.
    source_target = execution_target(simulation, :source, 1)
    other_target = execution_target(simulation, :source, 2)
    application = source_target.context.application
    @test PSE._model_execution_outputs_match(source_target.output_bindings,
        source_target.status_view, source_target.output_targets, application,
        source_target.object_id, simulation.output_retention, simulation.temporal_streams)
    @test !PSE._model_execution_outputs_match(source_target.output_bindings,
        other_target.status_view, source_target.output_targets, application,
        source_target.object_id, simulation.output_retention, simulation.temporal_streams)

    # Missing-view handling stays at the two existing gateways. Restore the
    # genuine entry even on failure; no kernel/refresh is performed while absent.
    key = (:source, ObjectId(1))
    views = simulation.compiled.status_views_by_target
    saved_view = pop!(views, key)
    try
        @test PSE._model_execution_target_change_reason(source_target,
            simulation.compiled, simulation.environment_bindings, application,
            simulation.output_retention, simulation.temporal_streams) === :missing_status_view
        @test_throws "No compiled status view" PSE._model_status_view_for_application(
            simulation.compiled, application, source_target.object_id)
    finally
        views[key] = saved_view
    end
    @test histories(simulation) == before_history
    @test source_runs[] == 3
    @test reader_runs[] == 2
end

end
