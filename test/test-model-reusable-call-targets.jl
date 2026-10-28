module ReusableCallTargetChecks

using Dates, PlantSimEngine, Test

const PSE = PlantSimEngine
const LEAF_DEFAULT_COEFFICIENTS = [1.0, 2.0]
PSE.@process "reusable_target_owner_probe" verbose=false
PSE.@process "reusable_target_leaf_probe" verbose=false
PSE.@process "reusable_target_middle_probe" verbose=false

struct CaptureOwner{C} <: AbstractReusable_Target_Owner_ProbeModel
    capture::C
end
PSE.outputs_(::CaptureOwner) = (visits=0, shared_driver=2.5)
function PSE.run!(model::CaptureOwner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end

struct Leaf <: AbstractReusable_Target_Leaf_ProbeModel end
struct AlternateLeaf <: AbstractReusable_Target_Leaf_ProbeModel end
PSE.inputs_(::AbstractReusable_Target_Leaf_ProbeModel) = (
    driver=Default(0.0), coefficients=Default(LEAF_DEFAULT_COEFFICIENTS),
)
PSE.outputs_(::AbstractReusable_Target_Leaf_ProbeModel) = (seen=0.0, calls=0)
PSE.environment_inputs_(::AbstractReusable_Target_Leaf_ProbeModel) = (T=0.0,)
function PSE.run!(::Leaf, status, environment, constants, context)
    status.calls += 1
    status.seen = status.driver + sum(status.coefficients) + environment.T
    return nothing
end
function PSE.run!(::AlternateLeaf, status, environment, constants, context)
    status.calls += 1
    status.seen = status.driver + sum(status.coefficients) + environment.T + 5
    return nothing
end

struct BorrowingMiddle{C} <: AbstractReusable_Target_Middle_ProbeModel
    capture::C
end
PSE.outputs_(::BorrowingMiddle) = (visits=0,)
function PSE.run!(model::BorrowingMiddle, status, environment, constants, context)
    with_call_targets(context, :leaves) do targets
        # Individual CallTarget values may safely escape the borrowed vector.
        model.capture[] = isempty(targets) ? nothing : first(targets)
    end
    status.visits += 1
    return nothing
end

function scene(::Type{S}=Float64; heterogeneous=false, empty=false) where {S}
    capture, child_capture = Ref{Any}(), Ref{Any}()
    leaf_input = (driver=One(id=:owner, within=SceneScope(),
        application=:owner, var=:shared_driver),)
    leaf_applications = heterogeneous ? (
        ModelSpec(Leaf(); name=:leaf_a, on=One(id=:leaf_a), inputs=leaf_input),
        ModelSpec(AlternateLeaf(); name=:leaf_b, on=One(id=:leaf_b), inputs=leaf_input),
    ) : (ModelSpec(Leaf(); name=:leaves, on=Many(scale=:Leaf), inputs=leaf_input),)
    leaf_application = heterogeneous ? :leaf_a : :leaves
    objects = Object[Object(:owner; scale=:Scene),
        Object(:middle; scale=:Plant, parent=:owner)]
    if !empty
        push!(objects, Object(:leaf_a; scale=:Leaf, parent=:middle),
            Object(:leaf_b; scale=:Leaf, parent=:middle))
    end
    model = CompositeModel(objects...; applications=(
        ModelSpec(CaptureOwner(capture); name=:owner, on=One(id=:owner), calls=(
            leaves=Many(scale=:Leaf, within=SceneScope(), process=:reusable_target_leaf_probe),
            first=OptionalOne(id=:leaf_a, within=SceneScope(), application=leaf_application),
            empty=Many(id=:newborn, within=SceneScope(), process=:reusable_target_leaf_probe),
            middle=One(id=:middle, within=SceneScope(), application=:middle),)),
        ModelSpec(BorrowingMiddle(child_capture); name=:middle, on=One(id=:middle),
            calls=(leaves=Many(scale=:Leaf, within=Subtree(), process=:reusable_target_leaf_probe),)),
        leaf_applications...,
    ), environment=[(date=DateTime(2026, 1, 1) + Hour(i - 1), duration=Hour(1),
        T=10.0 * (i + 1)) for i in 1:5], type_promotion=Dict(Float64 => S))
    return (; model, capture, child_capture)
end

ids(targets) = getproperty.(targets, :object_id)
rows(simulation, object=:leaf_a) = sort!(
    collect_outputs(simulation, object, :seen; sink=nothing); by=row -> row.timestep)

@testset "borrowed target vectors preserve concrete types and shared status" begin
    for S in (Float32, Float64), heterogeneous in (false, true)
        fixture = scene(S; heterogeneous)
        simulation = run!(fixture.model; steps=1, outputs=:all)
        context = fixture.capture[]
        # Test instrumentation retains the array only for identity comparison;
        # its contents are never accessed outside a with_call_targets lease.
        storage_identity = Ref{Any}(nothing)
        escaped = Ref{Any}()
        result = with_call_targets(context, :leaves) do targets
            storage_identity[] = targets
            @test targets isa Vector{<:CallTarget}
            @test ids(targets) == ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)]
            if heterogeneous
                @test targets[1].model isa Leaf
                @test targets[2].model isa AlternateLeaf
                @test typeof(targets[1]) !== typeof(targets[2])
            else
                @test isconcretetype(eltype(targets))
                @test typeof(targets[1]) === typeof(targets[2]) === eltype(targets)
            end
            escaped[] = first(targets)
            for target in targets
                @test target.status === model_status(fixture.model, target.object_id)
                @test target.status.driver === S(2.5)
                @test PSE.refvalue(target.status, :driver) ===
                    PSE.refvalue(model_status(fixture.model, :owner), :shared_driver)
                @test eltype(target.status.coefficients) === S
                @test target.status.coefficients !== LEAF_DEFAULT_COEFFICIENTS
            end
            :callback_result
        end
        @test result === :callback_result
        with_call_targets(call_targets(context, :leaves)) do targets
            @test targets === storage_identity[]
            @test first(targets).status === escaped[].status
        end
        with_call_targets(context, :leaves) do targets
            @test targets === storage_identity[]
            @test first(targets).status === escaped[].status
            first(targets).status.driver = S(4)
            @test model_status(fixture.model, :owner).shared_driver === S(4)
            first(targets).status.coefficients[1] = S(8)
            @test escaped[].status.coefficients === first(targets).status.coefficients
            run_call!(first(targets); publish=false)
            @test escaped[].status.seen === S(34)
        end
        @test isempty(rows(simulation))
        for name in (:empty,)
            with_call_targets(context, name) do targets
                @test targets isa Vector{<:CallTarget}
                @test isempty(targets)
                @test_throws BoundsError targets[1]
            end
        end
        with_call_targets(context, :first) do targets
            @test length(targets) == 1
            @test only(targets).object_id == ObjectId(:leaf_a)
        end
        @test LEAF_DEFAULT_COEFFICIENTS == [1.0, 2.0]
    end
end

@testset "leases refresh captured time environment and publication permission" begin
    for S in (Float32, Float64)
        fixture = scene(S)
        simulation = run!(fixture.model; steps=1, outputs=:all)
        old = with_call_targets(fixture.capture[], :leaves) do targets
            first(targets)
        end
        old_environment = old.environment
        middle = only(call_targets(fixture.capture[], :middle))
        rejected_environment = (T=50.0, duration=Hour(1))
        accepted_environment = (T=70.0, duration=Hour(1))
        run_call!(middle; environment=rejected_environment, publish=false)
        rejected = fixture.child_capture[]
        @test rejected.environment === rejected_environment
        @test !rejected.publication_allowed
        run_call!(middle; environment=accepted_environment, publish=true)
        accepted = fixture.child_capture[]
        @test accepted.environment === accepted_environment
        @test accepted.publication_allowed
        @test rejected.environment === rejected_environment
        @test !rejected.publication_allowed
        run_call!(rejected; publish=true)
        @test rejected.status.seen === S(55.5)
        @test isempty(rows(simulation))
        run_call!(accepted; publish=true)
        @test only(rows(simulation)).value === S(75.5)
        step!(simulation)
        with_call_targets(fixture.capture[], :leaves) do targets
            current = first(targets)
            @test old.time == 1 && current.time == 2
            @test old.status === current.status
            @test current.environment === fixture.capture[].environment
            @test old.publication_allowed && current.publication_allowed
            run_call!(current; publish=true)
            @test current.status.seen === S(35.5)
        end
        @test old.time == 1
        @test old.environment === old_environment
        run_call!(old; publish=true)
        @test old.status.seen === S(25.5)
        @test getproperty.(rows(simulation), :value) == S[25.5, 35.5]
    end
end

@testset "same-call reentry leases independent reusable storage and releases on failure" begin
    fixture = scene()
    run!(fixture.model; steps=1, outputs=:none)
    context = fixture.capture[]
    outer_identity, inner_identity = Ref{Any}(), Ref{Any}()
    with_call_targets(context, :leaves) do outer
        outer_identity[] = outer
        reverse!(outer)
        outer_ids = ids(outer)
        with_call_targets(context, :leaves) do inner
            inner_identity[] = inner
            @test inner !== outer
            @test ids(inner) == ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)]
            @test first(inner).status === last(outer).status
            first(inner).status.driver = 9.0
            inner_ids = ids(inner)
            with_call_targets(context, :leaves) do third
                @test third !== outer && third !== inner
                @test ids(third) == ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)]
                @test first(third).status === first(inner).status
                reverse!(third)
            end
            @test ids(inner) == inner_ids
            @test ids(outer) == outer_ids
        end
        @test ids(outer) == outer_ids
        @test last(outer).status.driver == 9.0
        @test_throws ErrorException with_call_targets(context, :leaves) do inner_failure
            @test inner_failure === inner_identity[]
            error("intentional second-depth borrowed-target failure")
        end
        @test ids(outer) == outer_ids
        with_call_targets(context, :leaves) do inner_again
            @test inner_again === inner_identity[]
            @test ids(inner_again) == ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)]
        end
    end
    with_call_targets(context, :leaves) do targets
        @test targets === outer_identity[]
        @test ids(targets) == ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)]
    end
    @test_throws ErrorException with_call_targets(context, :leaves) do targets
        @test targets === outer_identity[]
        error("intentional borrowed-target callback failure")
    end
    with_call_targets(context, :leaves) do targets
        @test targets === outer_identity[]
        @test length(targets) == 2
    end
end

@testset "one compiled call wrapper refreshes storage across environment types" begin
    for S in (Float32, Float64)
        fixture = scene(S)
        simulation = run!(fixture.model; steps=1, outputs=:all)
        targets = call_targets(fixture.capture[], :leaves)
        original_environment = targets.environment
        original_permission = targets.publication_allowed
        environment_a = (T=11.0, duration=Hour(1))
        environment_b = (T=22.0f0, duration=Hour(1), trial_kind=:b)
        environment_a_next = (T=44.0, duration=Hour(1))
        environment_c = (T=33.0, duration=Hour(1), trial_kind=true)
        identity_a, identity_b = Ref{Any}(), Ref{Any}()
        old_view = Ref{Any}()
        # Compiler-state unit: public manual calls specialize their RunContext
        # by environment type, so A and B ordinarily have different wrappers.
        # Assign only the metadata fields that the runtime itself refreshes to
        # exercise this cache's type key on one retained CallTargets wrapper.
        # Target acquisition and every child execution still use public APIs.
        try
            targets.environment = environment_a
            targets.publication_allowed = true
            with_call_targets(targets) do borrowed
                identity_a[] = borrowed # Identity only, never read after lease.
                old_view[] = first(borrowed)
                @test first(borrowed).environment === environment_a
                run_call!(first(borrowed); publish=true)
                @test first(borrowed).status.seen === S(16.5)
            end
            targets.environment = environment_b
            targets.publication_allowed = false
            with_call_targets(targets) do borrowed
                identity_b[] = borrowed
                @test borrowed !== identity_a[]
                @test isconcretetype(eltype(borrowed))
                @test first(borrowed).environment === environment_b
                @test !first(borrowed).publication_allowed
                @test first(borrowed).status === old_view[].status
                run_call!(first(borrowed); publish=true)
                @test first(borrowed).status.seen === S(27.5)
            end
            @test only(rows(simulation)).value === S(16.5)
            targets.environment = environment_a_next
            targets.publication_allowed = true
            with_call_targets(targets) do borrowed
                @test borrowed === identity_a[]
                @test borrowed !== identity_b[]
                @test first(borrowed).environment === environment_a_next
                @test first(borrowed).publication_allowed
                run_call!(first(borrowed); publish=true)
                @test first(borrowed).status.seen === S(49.5)
            end
            # A third type replaces one of the two inactive cache entries.
            # Returning to A must remain correct even if its old slot was evicted.
            for (environment, expected) in ((environment_c, S(38.5)),
                (environment_a, S(16.5)))
                targets.environment = environment
                with_call_targets(targets) do borrowed
                    @test isconcretetype(eltype(borrowed))
                    @test first(borrowed).environment === environment
                    @test first(borrowed).status === old_view[].status
                    run_call!(first(borrowed); publish=true)
                    @test first(borrowed).status.seen === expected
                end
            end
            @test old_view[].environment === environment_a
            @test old_view[].publication_allowed
            @test old_view[].time == 1
            @test old_view[].status.calls == 5
            @test only(rows(simulation)).value === S(16.5)
        finally
            targets.environment = original_environment
            targets.publication_allowed = original_permission
        end
    end
end

@testset "membership refresh observes empty growth removal and reparenting" begin
    for S in (Float32, Float64)
        fixture = scene(S; empty=true)
        simulation = run!(fixture.model; steps=1, outputs=:none)
        with_call_targets(fixture.capture[], :empty) do targets
            @test isempty(targets)
        end
        original = Status(driver=4.0, coefficients=[6.0, 7.0])
        register_object!(fixture.model,
            Object(:newborn; scale=:Leaf, parent=:middle, status=original))
        step!(simulation)
        first_status = with_call_targets(fixture.capture[], :empty) do targets
            @test length(targets) == 1
            @test isconcretetype(eltype(targets))
            newborn = only(targets)
            @test newborn.object_id == ObjectId(:newborn)
            @test newborn.status === model_status(fixture.model, :newborn)
            @test eltype(newborn.status.coefficients) === S
            run_call!(newborn; sampled_environment=(T=30.0,))
            @test newborn.status.seen === S(45.5)
            newborn.status
        end
        reparent_object!(fixture.model, :newborn, :owner)
        step!(simulation)
        with_call_targets(fixture.capture[], :empty) do targets
            current = only(targets).status
            canonical = model_status(fixture.model, :newborn)
            fresh = only(collect(call_targets(fixture.capture[], :empty)))
            @test current === fresh.status
            @test PSE.refvalue(current, :seen) === PSE.refvalue(canonical, :seen)
            @test PSE.refvalue(current, :coefficients) === PSE.refvalue(canonical, :coefficients)
            @test current.seen === first_status.seen
            @test current.coefficients == first_status.coefficients
            @test PSE.refvalue(current, :driver) ===
                PSE.refvalue(model_status(fixture.model, :owner), :shared_driver)
            run_call!(only(targets); sampled_environment=(T=31.0,))
            @test current.seen === S(46.5)
            @test canonical.seen === current.seen
        end
        middle = only(call_targets(fixture.capture[], :middle))
        run_call!(middle; publish=false)
        @test fixture.child_capture[] === nothing
        remaining = with_call_targets(fixture.capture[], :leaves) do targets
            length(targets)
        end
        @test remaining == 1
        remove_object!(fixture.model, :newborn)
        step!(simulation)
        with_call_targets(fixture.capture[], :empty) do targets
            @test isempty(targets)
        end
        @test middle.status === model_status(fixture.model, :middle)
    end
end

@testset "object-specific model overrides retain their target and status identities" begin
    for S in (Float32, Float64)
        capture = Ref{Any}()
        template = CompositeModelTemplate((
            ModelSpec(Leaf(); name=:leaf, on=Many(scale=:Leaf), inputs=(
                driver=One(id=:owner, within=SceneScope(), application=:owner,
                    var=:shared_driver),)),
        ))
        plant = ObjectInstance(:plant, template;
            root=Object(:plant; scale=:Plant, parent=:owner),
            objects=(Object(:leaf_a; scale=:Leaf, parent=:plant),
                Object(:leaf_b; scale=:Leaf, parent=:plant)),
            object_overrides=(Override(object=:leaf_b, application=:leaf,
                model=AlternateLeaf()),))
        model = CompositeModel(Object(:owner; scale=:Scene), plant; applications=(
            ModelSpec(CaptureOwner(capture); name=:owner, on=One(id=:owner), calls=(
                leaves=Many(scale=:Leaf, within=SceneScope(),
                    process=:reusable_target_leaf_probe),)),
        ), environment=(T=10.0, duration=Hour(1)), type_promotion=Dict(Float64 => S))
        simulation = run!(model; steps=1, outputs=:all)
        with_call_targets(capture[], :leaves) do targets
            @test ids(targets) == ObjectId[ObjectId(:leaf_a), ObjectId(:leaf_b)]
            @test targets[1].model isa Leaf
            @test targets[2].model isa AlternateLeaf
            for target in targets
                @test target.status === model_status(model, target.object_id)
                @test target.status.driver isa S
                run_call!(target; publish=true)
            end
        end
        @test only(rows(simulation, :leaf_a)).value === S(15.5)
        @test only(rows(simulation, :leaf_b)).value === S(20.5)
    end
end

@testset "borrowed targets compose with evaluate and accept without replay" begin
    fixture = scene()
    simulation = run!(fixture.model; steps=1, outputs=:all)
    with_call_targets(fixture.capture[], :leaves) do targets
        for target in targets
            evaluation = evaluate_call!(target; sampled_environment=(T=30.0,))
            @test target.status.calls == 1
            @test target.status.seen == 35.5
            accept_call!(evaluation)
            @test target.status.calls == 1
        end
    end
    @test only(rows(simulation, :leaf_a)).value == 35.5
    @test only(rows(simulation, :leaf_b)).value == 35.5
    evaluated = evaluate_call!(fixture.capture[], :leaves; sampled_environment=(T=40.0,))
    with_call_targets(fixture.capture[], :leaves) do targets
        @test all(target -> target.status.calls == 2, targets)
        @test all(target -> target.status.seen == 45.5, targets)
    end
    accept_call!(evaluated)
    @test only(rows(simulation, :leaf_a)).value == 45.5
end

Base.@noinline function read_targets(targets)
    result = zero(first(targets).status.seen)
    for target in targets
        result += target.status.seen
    end
    return result
end
function repeat_borrowed_reads(context, count)
    result = 0.0
    for _ in 1:count
        result += with_call_targets(read_targets, context, :leaves)
    end
    return result
end
function repeat_collected_reads(context, count)
    result = 0.0
    for _ in 1:count
        result += read_targets(collect(call_targets(context, :leaves)))
    end
    return result
end
borrowed_allocations(context, count) = @allocated repeat_borrowed_reads(context, count)
collected_allocations(context, count) = @allocated repeat_collected_reads(context, count)

@testset "warmed borrowed refill avoids repeated target collection allocations" begin
    fixture = scene()
    run!(fixture.model; steps=1, outputs=:none)
    context = fixture.capture[]
    with_call_targets(context, :leaves) do targets
        for target in targets
            run_call!(target; sampled_environment=(T=30.0,))
        end
    end
    repeat_borrowed_reads(context, 2304)
    repeat_collected_reads(context, 2304)
    borrowed_allocations(context, 1)
    collected_allocations(context, 1)
    borrowed_bytes = borrowed_allocations(context, 100)
    collected_bytes = collected_allocations(context, 100)
    @test repeat_borrowed_reads(context, 100) == repeat_collected_reads(context, 100) == 7100.0
    @test borrowed_bytes < collected_bytes
    # Allow a small constant callback/lookup cost across supported Julia
    # versions, without allowing a fresh target collection on each invocation.
    @test borrowed_bytes <= 100 * 256
    @test model_status(fixture.model, :leaf_a).calls == 1
    @test model_status(fixture.model, :leaf_b).calls == 1
end

end # module ReusableCallTargetChecks
