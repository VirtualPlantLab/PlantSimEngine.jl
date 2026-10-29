module StableStatusViewChecks

using PlantSimEngine, Serialization, Test
const PSE = PlantSimEngine
const View = PSE.CompiledModelStatusView

@testset "private status-view reference identity preserves diagnostic payload equivalence" begin
    status = Status(value=1.0)
    temporal = (Ref(2.0),)
    private = (scratch=Ref(3.0),)
    bound = (sources=Ref([4.0]),)
    view = View(status, status, temporal, private, bound)
    duplicate = View(status, status, temporal, private, bound)
    @test view !== duplicate
    @test PSE._same_model_status_view_payloads(view, view)
    @test PSE._same_model_status_view_payloads(view, duplicate)
    @test !PSE._same_model_status_view_payloads(view, nothing)
    @test !PSE._same_model_status_view_payloads(nothing, view)
    @test !ismutabletype(typeof(status))
    @test all(name -> isconst(typeof(view), name), fieldnames(typeof(view)))
    @test_throws ErrorException setfield!(view, :status, Status(value=5.0))

    # Equality of numerical Status values must not hide different carriers.
    equal_value = Status(value=1.0)
    @test status == equal_value
    variants = (
        View(equal_value, status, temporal, private, bound),
        View(status, equal_value, temporal, private, bound),
        View(status, status, (Ref(2.0),), private, bound),
        View(status, status, temporal, (scratch=Ref(3.0),), bound),
        View(status, status, temporal, private, (sources=Ref([4.0]),)),
    )
    @test all(other -> !PSE._same_model_status_view_payloads(view, other), variants)

    # Even identical payload identities do not equate differently typed wrappers.
    wider_temporal_type = View{typeof(status),typeof(status),Tuple,
        typeof(private),typeof(bound)}(status, status, temporal, private, bound)
    @test wider_temporal_type.temporal_inputs === view.temporal_inputs
    @test !PSE._same_model_status_view_payloads(view, wider_temporal_type)
    before = Dict(:same => view, :changed => view)
    after = Dict(:same => duplicate, :changed => first(variants), :new => duplicate)
    constructed = count(after) do (key, current)
        !PSE._same_model_status_view_payloads(get(before, key, nothing), current)
    end
    @test constructed == 2
    status.value = 7.0
    @test duplicate.status.value == 7.0
    @test PSE._same_model_status_view_payloads(view, duplicate)
end

PSE.@process "stable_view_source" verbose=false
PSE.@process "stable_view_lag" verbose=false
struct StableViewSource{T} <: AbstractStable_View_SourceModel
    initial::T
end
PSE.inputs_(::StableViewSource) = NamedTuple()
PSE.outputs_(model::StableViewSource) = (signal=model.initial,)
function PSE.run!(::StableViewSource, status, environment, constants, context)
    status.signal += one(status.signal)
    return nothing
end
struct StableViewLag{T} <: AbstractStable_View_LagModel
    initial::T
end
PSE.inputs_(model::StableViewLag) = (previous_signals=Default([model.initial]),)
PSE.outputs_(model::StableViewLag) = (lagged_total=model.initial,)
function PSE.run!(::StableViewLag, status, environment, constants, context)
    status.lagged_total = sum(status.previous_signals)
    return nothing
end

function stable_view_scene(::Type{T}) where {T}
    return CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:leaf_1; scale=:Leaf, parent=:scene);
        applications=(
            ModelSpec(StableViewSource(zero(T)); name=:source, on=Many(scale=:Leaf)),
            ModelSpec(StableViewLag(zero(T)); name=:lag, on=One(scale=:Scene),
                inputs=(PreviousTimeStep(:previous_signals) => Many(
                    scale=:Leaf, within=Subtree(), application=:source, var=:signal),)),
        ),
    )
end

function checkpoint(simulation)
    buffer = IOBuffer()
    serialize(buffer, simulation)
    seekstart(buffer)
    return deserialize(buffer)
end

@testset "private views retain temporal carriers over birth removal and checkpoints" begin
    for T in (Float32, Float64)
        simulation = run!(stable_view_scene(T); steps=1, outputs=:all, performance=true)
        model = simulation.model
        source_key = (:source, ObjectId(:leaf_1))
        lag_key = (:lag, ObjectId(:scene))
        original_source = simulation.compiled.status_views_by_target[source_key]
        original_lag = simulation.compiled.status_views_by_target[lag_key]
        temporal_input = only(original_lag.temporal_inputs)
        storage = temporal_input.reference[]
        first_reference = first(parent(storage))
        @test final_state(simulation, :scene).lagged_total == zero(T)

        register_object!(model, Object(:leaf_2; scale=:Leaf, parent=:scene))
        continue!(simulation; steps=1)
        @test simulation.compiled.status_views_by_target[source_key] === original_source
        @test simulation.compiled.status_views_by_target[lag_key] === original_lag
        @test only(original_lag.temporal_inputs) === temporal_input
        @test temporal_input.reference[] === storage
        @test first(parent(storage)) === first_reference
        @test length(storage) == 2
        @test final_state(simulation, :scene).lagged_total === one(T)
        newborn = simulation.compiled.status_views_by_target[(:source, ObjectId(:leaf_2))]
        @test newborn.canonical_status === model_status(model, :leaf_2)
        @test newborn.status.signal === one(T)

        remove_object!(model, :leaf_1)
        continue!(simulation; steps=1)
        @test !haskey(simulation.compiled.status_views_by_target, source_key)
        @test simulation.compiled.status_views_by_target[(:source, ObjectId(:leaf_2))] === newborn
        affected_lag = simulation.compiled.status_views_by_target[lag_key]
        @test affected_lag !== original_lag
        @test only(only(affected_lag.temporal_inputs).binding.source_ids) == ObjectId(:leaf_2)
        @test final_state(simulation, :scene).lagged_total === one(T)
        @test last.(outputs(simulation)[(:source, ObjectId(:leaf_1), :signal)]) == T[1, 2]

        restored = checkpoint(simulation)
        @test isequal(collect_outputs(restored), collect_outputs(simulation))
        restored_lag = restored.compiled.status_views_by_target[lag_key]
        @test PSE.refvalue(restored_lag.status, :previous_signals) ===
              only(restored_lag.temporal_inputs).reference
        @test restored_lag.canonical_status === model_status(restored.model, :scene)
        for current in (simulation, restored)
            continue!(current; steps=1)
        end
        @test isequal(collect_outputs(restored), collect_outputs(simulation))
        @test final_state(restored, :scene) == final_state(simulation, :scene)
        @test final_state(restored, :leaf_2) == final_state(simulation, :leaf_2)
        @test final_state(restored, :scene).lagged_total === T(2)
        snapshot = final_state(restored, :scene)
        snapshot.previous_signals[1] = T(-100)
        @test model_status(restored.model, :scene).previous_signals[1] != T(-100)
    end
end

end # module
