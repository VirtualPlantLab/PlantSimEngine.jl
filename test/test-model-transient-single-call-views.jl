module TransientSingleCallViewChecks

using Dates, PlantSimEngine, Test

const PSE = PlantSimEngine
const EA = PSE.EnvironmentAPI

PSE.@process "transient_single_view_owner_probe" verbose=false
PSE.@process "transient_single_view_middle_probe" verbose=false
PSE.@process "transient_single_view_leaf_probe" verbose=false

mutable struct MutableTrial{T}
    temperatures::NTuple{2,T}
end
struct AlternateTrial{T}
    temperatures::NTuple{2,T}
end
mutable struct ProbeBackend{T} <: EA.AbstractEnvironmentBackend
    temperatures::NTuple{2,T}
    samples::Int
end
EA.base_step_seconds(::ProbeBackend) = 3600.0
EA.get_nsteps(::ProbeBackend) = 8
EA.environment_variables(::ProbeBackend) = Set((:T,))
EA.bind_environment(::ProbeBackend, object::Object, context, config) =
    (; cell=isnothing(geometry(object)) ? 1 : geometry(object).cell)
function EA.sample(backend::ProbeBackend, handle, ::Symbol, time)
    backend.samples += 1
    value = backend.temperatures[handle.cell]
    return value + oftype(value, time)
end
function EA.sample(backend::ProbeBackend, handle,
    trial::Union{MutableTrial,AlternateTrial}, ::Symbol, time)
    backend.samples += 1
    return trial.temperatures[handle.cell]
end

struct Owner{C} <: AbstractTransient_Single_View_Owner_ProbeModel
    capture::C
end
PSE.outputs_(::Owner) = (visits=0,)
function PSE.run!(model::Owner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end

struct Leaf{T} <: AbstractTransient_Single_View_Leaf_ProbeModel
    initial::T
end
PSE.outputs_(model::Leaf) = (seen=model.initial, calls=0)
PSE.environment_inputs_(model::Leaf) = (T=model.initial,)
function PSE.run!(::Leaf, status, environment, constants, context)
    status.seen = environment.T + constants.offset
    status.calls += 1
    return nothing
end

struct Middle{T,C,H,R} <: AbstractTransient_Single_View_Middle_ProbeModel
    initial::T
    capture::C
    hook::H
    context_capture::R
end
PSE.outputs_(model::Middle) = (seen=model.initial, temperature=model.initial, calls=0)
PSE.environment_inputs_(model::Middle) = (T=model.initial,)
function PSE.run!(model::Middle, status, environment, constants, context)
    views = (one=only(call_targets(context, :one)),
        optional=only(call_targets(context, :optional)),
        many=only(call_targets(context, :many)))
    hook = model.hook[]
    if !isnothing(hook)
        model.hook[] = nothing
        hook()
    end
    run_call!(views.one; publish=true)
    model.capture[] = views
    model.context_capture[] = context
    status.seen = views.one.status.seen
    status.temperature = environment.T
    status.calls += 1
    return nothing
end

function fixture(::Type{S}) where {S}
    owner_capture, child_capture = Ref{Any}(), Ref{Any}()
    context_capture = Ref{Any}()
    hook = Ref{Any}(nothing)
    backend = ProbeBackend((S(10), S(20)), 0)
    model = CompositeModel(Object(:owner; scale=:Scene),
        Object(:middle; scale=:Branch, parent=:owner, geometry=(cell=1,)),
        Object(:leaf; scale=:Leaf, parent=:middle, geometry=(cell=2,),
            status=Status(seen=S(-999))); applications=(
            ModelSpec(Owner(owner_capture); name=:owner, on=One(id=:owner), calls=(
                middle=One(id=:middle, within=Subtree(), application=:middle),)),
            ModelSpec(Middle(zero(S), child_capture, hook, context_capture); name=:middle,
                on=One(id=:middle), calls=(
                    one=One(id=:leaf, within=Subtree(), application=:leaf),
                    optional=OptionalOne(id=:leaf, within=Subtree(), application=:leaf),
                    many=Many(id=:leaf, within=Subtree(), application=:leaf)),
                environment=Environment(provider=:transient_single_view_probe)),
            ModelSpec(Leaf(zero(S)); name=:leaf, on=One(id=:leaf),
                output_routing=(seen=:stream_only,),
                environment=Environment(provider=:transient_single_view_probe)),
        ), environment=backend, type_promotion=Dict(Float64 => S))
    simulation = run!(model; steps=1, outputs=:all, constants=(offset=zero(S),))
    return (; model, simulation, owner_capture, child_capture, context_capture, hook, backend)
end

raw(data) = outputs(data.simulation)[(:leaf, ObjectId(:leaf), :seen)]

@testset "transient singleton views keep live mutable sampling across all singular selectors" begin
    for S in (Float32, Float64)
        data = fixture(S)
        parent = only(call_targets(data.owner_capture[], :middle))
        trial = MutableTrial((S(30), S(40)))
        initial_samples = data.backend.samples
        run_call!(parent; environment=trial, publish=false)
        first_views = data.child_capture[]
        @test data.backend.samples == initial_samples + 2
        @test isempty(raw(data))
        for view in first_views
            @test view.environment === trial
            @test fieldtype(typeof(view), :environment) === typeof(trial)
            @test isconcretetype(typeof(view))
            @test view.status.seen === S(40)
            @test !view.publication_allowed
            @test view.time == 1
            @test view.status !== model_status(data.model, :leaf)
            @test view.canonical_status === model_status(data.model, :leaf)
        end
        @test first_views.one.status === first_views.optional.status === first_views.many.status

        # These are cache/sampling contracts, not a speed or allocation gate.
        # Reusing the same environment identity must not reuse sampled values.
        trial.temperatures = (S(31), S(41))
        run_call!(parent; environment=trial, publish=false)
        repeated_views = data.child_capture[]
        @test data.backend.samples == initial_samples + 4
        for name in keys(first_views)
            old, repeated = getproperty(first_views, name), getproperty(repeated_views, name)
            @test old === repeated
            @test old.status.seen === S(41)
            @test old.environment === trial
        end
        @test isempty(raw(data))
        @test model_status(data.model, :leaf).seen === S(-999)
    end
end

@testset "transient snapshots retain environment time and publication across metadata changes" begin
    for S in (Float32, Float64)
        data = fixture(S)
        parent = only(call_targets(data.owner_capture[], :middle))
        trial = MutableTrial((S(30), S(40)))
        run_call!(parent; environment=trial, publish=false)
        rejected = data.child_capture[]
        run_call!(parent; environment=trial, publish=true)
        accepted = data.child_capture[]
        @test raw(data) == [(1.0, S(40))]

        other = AlternateTrial((S(50), S(60)))
        run_call!(parent; environment=other, publish=false)
        switched = data.child_capture[]
        for name in keys(accepted)
            old, current = getproperty(accepted, name), getproperty(switched, name)
            @test current.environment === other
            @test fieldtype(typeof(current), :environment) === typeof(other)
            @test typeof(current) !== typeof(old)
            @test current.status === old.status
            @test current.status.seen === S(60)
            @test !current.publication_allowed && old.publication_allowed
            @test old.environment === trial
            @test !getproperty(rejected, name).publication_allowed
        end
        @test raw(data) == [(1.0, S(40))]

        step!(data.simulation)
        parent_now = only(call_targets(data.owner_capture[], :middle))
        later = MutableTrial((S(70), S(80)))
        run_call!(parent_now; environment=later, publish=true)
        current = data.child_capture[]
        for name in keys(current)
            latest, old = getproperty(current, name), getproperty(accepted, name)
            @test latest.time == 2 && old.time == 1
            @test latest.environment === later && old.environment === trial
            @test latest.publication_allowed && old.publication_allowed
            @test latest.status === old.status
        end
        @test sort(collect(raw(data)); by=first) == [(1.0, S(40)), (2.0, S(80))]

        # A retained rejected view cannot acquire permission from a later call.
        prefix = deepcopy(collect(raw(data)))
        trial.temperatures = (S(32), S(42))
        run_call!(rejected.one; publish=true)
        @test rejected.one.status.seen === S(42)
        @test isequal(collect(raw(data)), prefix)

        # An accepted old view still samples its original mutable carrier and
        # publishes at its captured time rather than the latest lookup's time.
        run_call!(accepted.optional; publish=true)
        @test accepted.optional.status.seen === S(42)
        @test sort(collect(raw(data)); by=first) == [(1.0, S(42)), (2.0, S(80))]
        @test accepted.optional.environment === trial
        @test current.optional.environment === later
    end
end

@testset "same-target reentry preserves the outer transient singleton and its descendants" begin
    for S in (Float32, Float64)
        data = fixture(S)
        parent = only(call_targets(data.owner_capture[], :middle))
        outer_trial = MutableTrial((S(70), S(80)))
        inner_trial = AlternateTrial((S(50), S(60)))
        inner_capture, inner_parent_capture = Ref{Any}(), Ref{Any}()
        initial_samples = data.backend.samples
        data.hook[] = () -> begin
            # Materialize during the active parent lease to exercise reentry,
            # after the outer model has already acquired its child views.
            inner_parent = only(call_targets(data.owner_capture[], :middle))
            inner_parent_capture[] = inner_parent
            run_call!(inner_parent; environment=inner_trial, publish=false)
            inner_capture[] = data.child_capture[]
        end
        run_call!(parent; environment=outer_trial, publish=true)
        outer = data.child_capture[]
        inner = inner_capture[]
        @test data.backend.samples == initial_samples + 4
        @test parent.status.temperature === S(70)
        @test parent.status.seen === S(80)
        @test inner_parent_capture[].calls !== parent.calls
        for name in keys(outer)
            outer_view, inner_view = getproperty(outer, name), getproperty(inner, name)
            @test outer_view.environment === outer_trial
            @test inner_view.environment === inner_trial
            @test outer_view.publication_allowed && !inner_view.publication_allowed
            @test outer_view.time == inner_view.time == 1
            @test outer_view.status === inner_view.status
        end
        @test raw(data) == [(1.0, S(80))]
        @test isnothing(data.hook[])

        outer_trial.temperatures = (S(71), S(81))
        run_call!(parent; environment=outer_trial, publish=false)
        @test parent.status.seen === S(81)
        @test !data.child_capture[].one.publication_allowed
        @test raw(data) == [(1.0, S(80))]
    end
end

@noinline function escape_transient_single_views!(sink::Base.RefValue{Any}, targets, count)
    for _ in 1:count
        sink[] = only(targets)
    end
    return nothing
end

# Preserve the caller's statically known constants type across view lookup,
# independently of the transient environment's dynamically selected type.
@noinline captured_offset(targets) = only(targets).constants.offset

function transient_lookup_allocations(sink, targets, count)
    return @allocated escape_transient_single_views!(sink, targets, count)
end

@testset "warmed escaping transient singleton lookups allocate no per-access wrappers" begin
    for S in (Float32, Float64)
        data = fixture(S)
        parent = only(call_targets(data.owner_capture[], :middle))
        sink = Ref{Any}()
        trial = MutableTrial((S(30), S(40)))
        # Warm construction/cache hits, every selector, and the measurement
        # helper twice. Numerical calls and GC are outside allocation capture.
        for _ in 1:2
            trial = MutableTrial((S(30), S(40)))
            run_call!(parent; environment=trial, publish=false)
            for name in (:one, :optional, :many)
                targets = call_targets(data.context_capture[], name)
                escape_transient_single_views!(sink, targets, 1000)
                transient_lookup_allocations(sink, targets, 1000)
            end
        end
        GC.gc()
        samples_before = data.backend.samples
        for name in (:one, :optional, :many)
            targets = call_targets(data.context_capture[], name)
            @test transient_lookup_allocations(sink, targets, 1000) == 0
            @test (@inferred captured_offset(targets)) === zero(S)
            @test sink[] isa PSE.CallTarget
            @test sink[].environment === trial
            @test sink[].status.seen === S(40)
            @test !sink[].publication_allowed
        end
        @test data.backend.samples == samples_before
        @test isempty(raw(data))
    end
end

end # module TransientSingleCallViewChecks
