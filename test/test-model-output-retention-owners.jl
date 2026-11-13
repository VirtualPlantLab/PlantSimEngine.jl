module OutputRetentionOwnerChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine

PSE.@process "retention_owner_writer" verbose=false
PSE.@process "retention_owner_reader" verbose=false
PSE.@process "retention_owner_distributor" verbose=false

struct Writer <: AbstractRetention_Owner_WriterModel end
PSE.inputs_(::Writer) = NamedTuple()
PSE.outputs_(::Writer) = (live=0f0, private=0f0)
function PSE.run!(::Writer, status, environment, constants, context)
    status.live = Float32(context.time)
    status.private = 2f0 * status.live
    return nothing
end

struct Reader <: AbstractRetention_Owner_ReaderModel end
PSE.inputs_(::Reader) = (lag=Default(Float32[]),)
PSE.outputs_(::Reader) = (seen=0f0,)
PSE.run!(::Reader, status, environment, constants, context) =
    (status.seen = sum(status.lag; init=0f0); nothing)

function local_scene(; temporal=false, status_transform=nothing)
    specs = (ModelSpec(Writer(); name=:writer, on=Many(scale=:Leaf),
        output_routing=(private=:stream_only,)),)
    if temporal
        specs = (specs..., ModelSpec(Reader(); name=:reader, on=One(id=0),
            inputs=(PreviousTimeStep(:lag) => Many(SceneScope(); scale=:Leaf,
                application=:writer, var=:private),)))
    end
    return CompositeModel(Object(0; scale=:Scene), Object(1; scale=:Leaf, parent=0);
        applications=specs, status_transform)
end

stream(simulation, application, id, variable) =
    simulation.temporal_streams[(application, ObjectId(id), variable)]

mutable struct ViewConstructionTrace
    families::Dict{Symbol,Vector{DataType}}
    views::Vector{Any}
end
ViewConstructionTrace() = ViewConstructionTrace(Dict{Symbol,Vector{DataType}}(), Any[])
PSE._construct_model_status_view(trace::ViewConstructionTrace, application::Symbol, parts) =
    PSE._construct_model_status_view(nothing, application, parts)
@inline function PSE._with_temporal_copy_payloads(f::F, ::ViewConstructionTrace,
    binding, status, args::Vararg{Any,N},
) where {F,N}
    return f(nothing, binding, status, args...)
end
function PSE._admit_model_status_view!(trace::ViewConstructionTrace, application::Symbol, view)
    types = get!(Vector{DataType}, trace.families, application)
    typeof(view) in types || push!(types, typeof(view))
    push!(trace.views, view)
    return view
end
function PSE._with_model_status_view(f::F, ::ViewConstructionTrace, application::Symbol,
    view, args::Vararg{Any,N},
) where {F,N}
    return f(view, args...)
end
function construction_family_schema(trace)
    ids = (:writer, :reader)
    return PSE.CompiledMetadataTable(NamedTuple{ids}(map(ids) do id
        Vector{Union{trace.families[id]...}}()
    end))
end
function construction_trace(; schema=ViewConstructionTrace(), prototype=nothing)
    conversions = Symbol[]
    transform = (variable, value) -> (push!(conversions, variable); value)
    model = local_scene(; temporal=true, status_transform=transform)
    simulation = PSE._prepare_simulation!(model; steps=0, outputs=:none,
        constants=PSE.Constants(), status_view_schema=schema,
        input_binding_storage=prototype)
    bindings = DataType[]
    snapshots = Any[]
    function checkpoint!()
        for binding in simulation.compiled.input_bindings
            typeof(binding) in bindings || push!(bindings, typeof(binding))
        end
        views = Dict(key => (type=typeof(view), status=deepcopy(NamedTuple(view.status)),
            initials=map(input -> deepcopy(input.initial), view.temporal_inputs),
            ids=map(input -> copy(input.binding.source_ids), view.temporal_inputs))
            for (key, view) in simulation.compiled.status_views_by_target)
        for view in values(simulation.compiled.status_views_by_target), name in propertynames(view.bound_inputs)
            @test getproperty(view.bound_inputs, name).values === getproperty(view.status, name)
        end
        push!(snapshots, (views=views,
            history=Dict(key => collect(value) for (key, value) in simulation.temporal_streams)))
    end
    checkpoint!()
    step!(simulation); checkpoint!()
    step!(simulation); checkpoint!()
    key = (:writer, ObjectId(1))
    private = simulation.compiled.status_views_by_target[key].private_outputs.private
    register_object!(model, Object(2; scale=:Leaf, parent=0))
    step!(simulation); checkpoint!()
    @test simulation.compiled.status_views_by_target[key].private_outputs.private === private
    remove_object!(model, 1)
    remove_object!(model, 2)
    step!(simulation); checkpoint!()
    register_object!(model, Object(3; scale=:Leaf, parent=0))
    step!(simulation); checkpoint!()

    # The actual constructor is also used for a partial, ephemeral target.
    compiled = simulation.compiled
    current = compiled.applications_by_id[:writer]
    partial = PSE._partial_model_application(current, [ObjectId(3)])
    positions = Dict(id => index for (index, id) in pairs(compiled.application_order))
    target_key = (:writer, ObjectId(3))
    previous = compiled.status_views_by_target[target_key]
    stamp = Ref(UInt64(0))
    prior_view_count = schema isa ViewConstructionTrace ? length(schema.views) : 0
    ephemeral = PSE._compile_model_status_view(model, partial, ObjectId(3), (),
        compiled.applications_by_id, positions, compiled.distributed_outputs;
        execution_stamp=stamp, status_view_schema=schema,
        input_binding_storage=compiled.input_bindings)
    @test ephemeral.execution_stamp === stamp
    @test ephemeral.canonical_status === previous.canonical_status
    @test PSE.refvalue(ephemeral.status, :live) === PSE.refvalue(previous.status, :live)
    @test ephemeral.private_outputs.private isa Base.RefValue{Float32}
    @test compiled.status_views_by_target[target_key] === previous
    if schema isa ViewConstructionTrace
        @test length(schema.views) == prior_view_count + 1
        @test last(schema.views) === ephemeral
    end
    return (; simulation, schema, bindings, snapshots, conversions)
end

@testset "real view factories retain private Float32 and temporal Many through lifecycle" begin
    control = construction_trace()
    schema = construction_family_schema(control.schema)
    prototype = Vector{Union{control.bindings...}}()
    finite = construction_trace(; schema, prototype)
    @test finite.snapshots == control.snapshots
    @test finite.conversions == control.conversions
    @test isempty(prototype)
    @test all(isempty, values(schema))
    @test all(typeof(view) in control.schema.families[application]
        for ((application, _), view) in finite.simulation.compiled.status_views_by_target)

    simulation = finite.simulation
    compiled = simulation.compiled
    reader = only(binding for binding in compiled.input_bindings
        if binding.application_id === :reader)
    PSE._with_temporal_copy_payloads(schema, reader,
        model_status(simulation.model, 0)) do payloads, binding, status
        # Each value is deliberately read through Any, as between the copies.
        values = Any[2f0]
        first_copy = @inferred PSE._copy_temporal_status_value(payloads, values[1])
        second_values = Any[first_copy]
        second_copy = @inferred PSE._copy_temporal_status_value(payloads, second_values[1])
        @test first_copy === second_copy === 2f0
        @test_throws "outside its prepared input family" PSE._copy_temporal_status_value(payloads, 2.0)
    end
    previous_owner = simulation.model.binding_cache
    key = (:writer, ObjectId(3))
    before = compiled.status_views_by_target[key]
    invalid = PSE.CompiledMetadataTable((writer=Vector{Union{}}(),))
    positions = Dict(id => index for (index, id) in pairs(compiled.application_order))
    @test_throws "outside supported prepared application view families" PSE._compile_model_status_view(
        simulation.model, compiled.applications_by_id[:writer], ObjectId(3), (),
        compiled.applications_by_id, positions, compiled.distributed_outputs;
        execution_stamp=before.execution_stamp, status_view_schema=invalid,
        input_binding_storage=compiled.input_bindings)
    @test simulation.model.binding_cache === previous_owner
    @test compiled.status_views_by_target[key] === before
end

@testset "callback lookup preserves identity and missing-application diagnostics" begin
    simulation = run!(local_scene(); steps=0, outputs=:none)
    compiled = simulation.compiled
    application = compiled.applications_by_id[:writer]
    @test PSE._compiled_application_by_id(compiled, :writer) === application
    @test PSE._compiled_application_by_id(identity, compiled, :writer) === application
    @test PSE._compiled_application_by_id(compiled, :writer) do selected
        selected.id === :writer && selected.plan === application.plan
    end
    error = try
        PSE._compiled_application_by_id(identity, compiled, :missing)
        nothing
    catch exception
        exception
    end
    @test error isa ErrorException
    @test sprint(showerror, error) == "No compiled model application with id `missing`."
    @test current_step(simulation) == 0
end

@testset "none, all and selective local retention keep stream-only ownership and removed history" begin
    request = OutputRequest(Many(scale=:Leaf), :private; name=:chosen, application=:writer)
    for selection in (:none, :all, request)
        simulation = run!(local_scene(); steps=2, outputs=selection)
        @test model_status(simulation.model, 1).live === 2f0
        @test !hasproperty(model_status(simulation.model, 1), :private)
        retained = simulation.output_retention
        @test eltype(retained.temporal_dependencies) === Tuple{Symbol,Symbol}
        @test eltype(retained.requested_outputs) === Tuple{Symbol,Symbol}
        if selection === :none
            @test isempty(simulation.temporal_streams)
        else
            @test stream(simulation, :writer, 1, :private) == [(1.0, 2f0), (2.0, 4f0)]
            @test haskey(simulation.temporal_streams, (:writer, ObjectId(1), :live)) ==
                (selection === :all)
        end
        register_object!(simulation.model, Object(2; scale=:Leaf, parent=0))
        step!(simulation)
        @test model_status(simulation.model, 2).live === 3f0
        @test !hasproperty(model_status(simulation.model, 2), :private)
        old_history = selection === :none ? nothing : stream(simulation, :writer, 1, :private)
        before_removal = isnothing(old_history) ? nothing : copy(old_history)
        remove_object!(simulation.model, 1)
        step!(simulation)
        @test model_status(simulation.model, 2).live === 4f0
        if selection === :none
            @test isempty(simulation.temporal_streams)
        else
            @test stream(simulation, :writer, 1, :private) === old_history
            @test old_history == before_removal
            @test stream(simulation, :writer, 2, :private) == [(3.0, 6f0), (4.0, 8f0)]
        end
    end
end

@testset "dependency-only temporal streams survive source growth and removal" begin
    simulation = run!(local_scene(; temporal=true); steps=2, outputs=:none)
    @test model_status(simulation.model, 0).seen === 2f0
    original_retention = simulation.output_retention
    @test (:writer, :private) in original_retention.temporal_dependencies
    @test isempty(original_retention.requested_outputs)
    @test stream(simulation, :writer, 1, :private) isa PSE.TemporalDependencyBuffer{Float32}
    register_object!(simulation.model, Object(2; scale=:Leaf, parent=0))
    continue!(simulation; steps=2)
    @test model_status(simulation.model, 0).seen === 12f0
    @test PSE._model_output_retention_covers_addition(simulation.output_retention, simulation.compiled)
    @test simulation.output_retention === original_retention
    first_history = stream(simulation, :writer, 1, :private)
    removed_samples = collect(first_history)
    remove_object!(simulation.model, 1)
    step!(simulation)
    @test model_status(simulation.model, 0).seen === 8f0
    @test stream(simulation, :writer, 1, :private) === first_history
    @test collect(first_history) == removed_samples
    @test stream(simulation, :writer, 2, :private) isa PSE.TemporalDependencyBuffer{Float32}
end

struct Distributor <: AbstractRetention_Owner_DistributorModel end
PSE.inputs_(::Distributor) = NamedTuple()
PSE.outputs_(::Distributor) = (delivered=Distributed(Default(0f0)),)
function PSE.run!(::Distributor, status, environment, constants, context)
    destinations = output_targets(context, (:delivered,))
    for index in eachindex(object_ids(destinations))
        destinations.columns.delivered[index] = Float32(context.time)
    end
    return nothing
end
function distributed_scene(; with_leaf=true)
    objects = with_leaf ? (Object(0; scale=:Scene), Object(1; scale=:Leaf, parent=0)) :
        (Object(0; scale=:Scene),)
    return CompositeModel(objects...; applications=(
        ModelSpec(Distributor(); name=:distributed, on=One(id=0),
            outputs_to=(OutputTo(Many(Subtree(); scale=:Leaf); vars=(:delivered,)),)),))
end

@testset "distributed destinations keep none/all/selective retention and removed samples" begin
    request = OutputRequest(Many(scale=:Leaf), :delivered;
        name=:distributed_values, application=:distributed)
    for selection in (:none, :all, request)
        simulation = run!(distributed_scene(); steps=2, outputs=selection)
        register_object!(simulation.model, Object(2; scale=:Leaf, parent=0))
        step!(simulation)
        @test model_status(simulation.model, 1).delivered === 3f0
        @test model_status(simulation.model, 2).delivered === 3f0
        old_history = selection === :none ? nothing : stream(simulation, :distributed, 1, :delivered)
        removed_samples = isnothing(old_history) ? nothing : copy(old_history)
        remove_object!(simulation.model, 1)
        step!(simulation)
        @test model_status(simulation.model, 2).delivered === 4f0
        if selection === :none
            @test isempty(simulation.temporal_streams)
        else
            @test stream(simulation, :distributed, 1, :delivered) === old_history
            @test old_history == removed_samples
            @test stream(simulation, :distributed, 2, :delivered) == [(3.0, 3f0), (4.0, 4f0)]
        end
    end
end

@testset "initially empty distributed declarations still retain future outputs" begin
    simulation = run!(distributed_scene(; with_leaf=false); steps=0, outputs=:all)
    @test simulation.output_retention.retained_outputs_by_application[:distributed] == [:delivered]
    @test isempty(simulation.temporal_streams)
    register_object!(simulation.model, Object(1; scale=:Leaf, parent=0))
    step!(simulation)
    @test stream(simulation, :distributed, 1, :delivered) == [(1.0, 1f0)]
    retained_stream = stream(simulation, :distributed, 1, :delivered)
    PSE._initialize_model_output_streams!(simulation.temporal_streams, simulation.compiled,
        simulation.output_retention, 0, [(:distributed, ObjectId(0))])
    @test stream(simulation, :distributed, 1, :delivered) === retained_stream
    @test retained_stream == [(1.0, 1f0)]
end

end
