module PSEStatusTargetMicrobench

using Dates, PlantSimEngine, Statistics
const PSE = PlantSimEngine

# Standalone public-API fixtures. Existing lightweight-target test files execute
# their testsets when included, so this helper does not include those files.
PSE.@process "status_target_micro_owner" verbose=false
PSE.@process "status_target_micro_middle" verbose=false
PSE.@process "status_target_micro_leaf" verbose=false

struct MicroOwner{C} <: AbstractStatus_Target_Micro_OwnerModel
    capture::C
end
PSE.inputs_(::MicroOwner) = NamedTuple()
PSE.outputs_(::MicroOwner) = (visits=0,)
PSE.environment_inputs_(::MicroOwner) = NamedTuple()
function PSE.run!(model::MicroOwner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end

struct MicroMiddle{C} <: AbstractStatus_Target_Micro_MiddleModel
    capture::C
end
PSE.inputs_(::MicroMiddle) = NamedTuple()
PSE.outputs_(::MicroMiddle) = (visits=0,)
PSE.environment_inputs_(::MicroMiddle) = NamedTuple()
function PSE.run!(model::MicroMiddle, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end

struct MicroLeaf{T} <: AbstractStatus_Target_Micro_LeafModel
    offset::T
end
PSE.inputs_(model::MicroLeaf) = (driven=Default(zero(model.offset)),)
PSE.outputs_(model::MicroLeaf) = (seen=zero(model.offset),)
PSE.environment_inputs_(::MicroLeaf) = NamedTuple()
function PSE.run!(model::MicroLeaf, status, environment, constants, context)
    status.seen = status.driven + model.offset
    return nothing
end

function fixture(::Type{T}) where {T}
    owner_capture, middle_capture = Ref{Any}(), Ref{Any}()
    owner_id, middle_id = :micro_owner, :micro_middle
    ids = ntuple(i -> Symbol(:micro_leaf_, i), 8)
    leaf(id) = Object(id; scale=:Leaf, parent=owner_id,
        status=Status(driven=T(2), seen=zero(T)))
    model = CompositeModel(
        Object(owner_id; scale=:Scene),
        Object(middle_id; scale=:Branch, parent=owner_id),
        (leaf(id) for id in ids)...;
        applications=(
            ModelSpec(MicroOwner(owner_capture); name=:micro_owner, on=One(id=owner_id), calls=(
                one=One(id=ids[1], within=SceneScope(), application=:micro_leaves),
                optional=OptionalOne(id=ids[1], within=SceneScope(), application=:micro_leaves),
                optional_empty=OptionalOne(id=:missing, within=SceneScope(), application=:micro_leaves),
                empty=Many(id=:missing, within=SceneScope(), application=:micro_leaves),
                many=Many(scale=:Leaf, within=SceneScope(), application=:micro_leaves),
                nested=One(id=middle_id, within=SceneScope(), application=:micro_middle),
            )),
            ModelSpec(MicroMiddle(middle_capture); name=:micro_middle, on=One(id=middle_id), calls=(
                child=One(id=ids[1], within=SceneScope(), application=:micro_leaves),
            )),
            ModelSpec(MicroLeaf(T(1)); name=:micro_leaves, on=Many(scale=:Leaf)),
        ), environment=(duration=Hour(1),), type_promotion=Dict(Float64 => T))
    simulation = run!(model; steps=1, outputs=:none)
    context = owner_capture[]
    collections = NamedTuple{(:one, :optional, :optional_empty, :empty, :many, :nested)}(
        map(name -> call_targets(context, name), (:one, :optional, :optional_empty, :empty, :many, :nested)))
    @assert length(collections.many) == 8
    @assert isempty(collections.empty) && isempty(collections.optional_empty)
    for name in (:one, :optional, :nested)
        targets = getproperty(collections, name)
        @assert length(targets) == 1
        @assert only(targets).status === first(collect(targets)).status
    end
    @assert call_model(context, :one) === only(collections.one).model
    @assert getproperty.(collect(collections.many), :object_id) == getproperty.(collections.many, :object_id)

    # Capture a non-default typed backend environment in the nested call tree.
    trial = (duration=Hour(1), trial_marker=T(7))
    run_call!(only(collections.nested); environment=trial, publish=false)
    nested_child = call_targets(middle_capture[], :child)
    @assert only(nested_child).environment === trial
    @assert !only(nested_child).publication_allowed

    return (; model, simulation, context, collections, nested_child)
end

function retained_newborn(fixture_data, ::Type{T}) where {T}
    # Prepare after all clean-topology cases, so Many8 really stays eight.
    # Existing inputs are seeded identically to avoid unrelated schema widening.
    newborn = Object(:micro_newborn; scale=:Leaf, parent=:micro_owner,
        status=Status(driven=T(2), seen=zero(T)))
    register_object!(fixture_data.model, newborn)
    selected = call_targets(fixture_data.context, :many; objects=newborn)
    @assert length(selected) == 1 && only(selected).object_id == ObjectId(:micro_newborn)
    @assert first(collect(selected)).status === only(selected).status
    return selected
end

# No-inline wrappers make the escaped materialization boundary equal in both
# engines. Every result goes into an external Ref; nothing is optimized away.
Base.@noinline collect_targets(targets) = collect(targets)
Base.@noinline only_target(targets) = only(targets)
Base.@noinline indexed_target(targets) = targets[1]
Base.@noinline iterated_target(targets) = iterate(targets)
Base.@noinline literal_get(status) = status.temperature
Base.@noinline dynamic_get(status, names) = getproperty(status, names[1])
Base.@noinline literal_set(status, value) = (status.temperature = value; nothing)
Base.@noinline dynamic_set(status, names, value) = (setproperty!(status, names[1], value); nothing)

# These kernels receive the collected vector through a function boundary, as a
# downstream caller would. Keep collection itself outside their timed regions.
Base.@noinline function read_collected(targets, initial)
    value = initial
    for target in targets
        value += target.status.driven
    end
    return value
end
Base.@noinline function write_collected(targets)
    for target in targets
        target.status.seen = target.status.driven
    end
    return nothing
end

function repeat_calls(f::F, a::A, b::B, count::Int, sink::R) where {F,A,B,R}
    for i in 1:count
        sink[] = f((isodd(i) ? a : b)...)
    end
    return nothing
end

function measure(f, a, b, sink; calls, repetitions)
    repeat_calls(f, a, b, min(calls, 100), sink)
    samples = map(1:repetitions) do _
        GC.gc()
        timed = @timed repeat_calls(f, a, b, calls, sink)
        (ns=1e9 * timed.time / calls, bytes=timed.bytes / calls,
            compile_seconds=timed.compile_time, recompile_seconds=timed.recompile_time)
    end
    return (ns_per_call=median(x.ns for x in samples),
        bytes_per_call=median(x.bytes for x in samples),
        max_compile_seconds=maximum(x.compile_seconds for x in samples),
        max_recompile_seconds=maximum(x.recompile_seconds for x in samples))
end

"""
    run_microbench(; calls=1000, repetitions=5)

Return compact scalar diagnostic timings for escaped public target views and
Status access. Fixture setup, model compilation, newborn registration and
correctness checks are outside timing. This is not a scenario speedup claim.
"""
function run_microbench(; calls=1_000, repetitions=5)
    calls > 0 && repetitions > 0 || throw(ArgumentError("positive calls/repetitions required"))
    rows = NamedTuple[]
    for T in (Float32, Float64)
        fixture_data = fixture(T)
        c = fixture_data.collections
        escaped = Ref{Any}()
        cases = (
            (:collect_one, collect_targets, c.one),
            (:only_one, only_target, c.one),
            (:collect_optional, collect_targets, c.optional),
            (:only_optional, only_target, c.optional),
            (:collect_optional_empty, collect_targets, c.optional_empty),
            (:collect_many_empty, collect_targets, c.empty),
            (:collect_many8, collect_targets, c.many),
            (:index_many8, indexed_target, c.many),
            (:iterate_many8, iterated_target, c.many),
            (:collect_nested, collect_targets, c.nested),
            (:only_nested, only_target, c.nested),
            (:only_nested_child_trial, only_target, fixture_data.nested_child),
        )
        for (name, f, targets) in cases
            stats = measure(f, (targets,), (targets,), escaped; calls, repetitions)
            push!(rows, merge((case=name, numeric_type=string(T)), stats))
        end
        collected = collect(c.many)
        @assert read_collected(collected, zero(T)) === T(16)
        write_collected(collected)
        @assert all(target -> target.status.seen === T(2), collected)
        for (name, f, arguments, sink) in (
            (:status_read_collected_many8, read_collected, (collected, zero(T)), Ref(zero(T))),
            (:status_write_collected_many8, write_collected, (collected,), Ref(nothing)),
        )
            stats = measure(f, arguments, arguments, sink; calls, repetitions)
            push!(rows, merge((case=name, numeric_type=string(T)), stats))
        end
        selected = retained_newborn(fixture_data, T)
        for (name, f) in ((:collect_retained_newborn, collect_targets),
                          (:only_retained_newborn, only_target))
            stats = measure(f, (selected,), (selected,), escaped; calls, repetitions)
            push!(rows, merge((case=name, numeric_type=string(T)), stats))
        end

        # Public Ref-valued construction retains exactly the same shared binding.
        # Mixed scalar/vector types reflect heterogeneous scientific Status rows.
        refs = (temperature=Ref(T(25)), humidity=Ref(T(.6)), flag=Ref(false),
            iterations=Ref(2), vector=Ref(T[1, 2]))
        status, alias = Status(refs), Status(refs)
        names = Symbol[:temperature] # mutable lookup prevents literal-name propagation
        @assert literal_get(status) === dynamic_get(status, names) === T(25)
        dynamic_set(status, names, T(26))
        @assert alias.temperature === T(26)
        literal_set(status, T(27))
        @assert alias.temperature === T(27) && alias.vector === status.vector === refs.vector[]
        scalar_sink, void_sink = Ref(zero(T)), Ref(nothing)
        access_cases = (
            (:status_literal_get, literal_get, (status,), (status,), scalar_sink),
            (:status_dynamic_get, dynamic_get, (status, names), (status, names), scalar_sink),
            (:status_literal_set, literal_set, (status, T(25)), (status, T(26)), void_sink),
            (:status_dynamic_set, dynamic_set, (status, names, T(25)), (status, names, T(26)), void_sink),
        )
        for (name, f, a, b, sink) in access_cases
            stats = measure(f, a, b, sink; calls, repetitions)
            @assert alias.temperature === status.temperature
            @assert alias.vector === refs.vector[]
            push!(rows, merge((case=name, numeric_type=string(T)), stats))
        end
    end
    return (julia=string(VERSION), project=Base.active_project(),
        pse_path=Base.pathof(PSE), pse_version=string(Base.pkgversion(PSE)),
        calls, repetitions, rows)
end

end # module
