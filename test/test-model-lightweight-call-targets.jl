module LightweightCallTargetChecks

using Dates
using PlantSimEngine
using Test

const PSE = PlantSimEngine

PSE.@process "lightweight_target_owner_probe" verbose=false
PSE.@process "lightweight_target_driver_probe" verbose=false
PSE.@process "lightweight_target_middle_probe" verbose=false
PSE.@process "lightweight_target_leaf_probe" verbose=false

struct ViewOwner{C} <: AbstractLightweight_Target_Owner_ProbeModel
    capture::C
end
PSE.inputs_(::ViewOwner) = (ready=Default(0.0),)
PSE.outputs_(::ViewOwner) = (visits=0,)
PSE.environment_inputs_(::ViewOwner) = NamedTuple()
PSE.environment_outputs_(::ViewOwner) = NamedTuple()
function PSE.run!(model::ViewOwner, status, environment, constants, context)
    model.capture[] = context
    status.visits += 1
    return nothing
end

struct ViewDriver <: AbstractLightweight_Target_Driver_ProbeModel end
PSE.inputs_(::ViewDriver) = NamedTuple()
PSE.outputs_(::ViewDriver) = (driver=0.0,)
PSE.environment_inputs_(::ViewDriver) = (driver_value=0.0,)
PSE.environment_outputs_(::ViewDriver) = NamedTuple()
function PSE.run!(::ViewDriver, status, environment, constants, context)
    status.driver = environment.driver_value
    return nothing
end

struct ViewLeaf <: AbstractLightweight_Target_Leaf_ProbeModel end
PSE.inputs_(::ViewLeaf) = (called_input=Default(0.0),)
PSE.outputs_(::ViewLeaf) = (leaf_seen=0.0,)
PSE.environment_inputs_(::ViewLeaf) = (T=0.0,)
PSE.environment_outputs_(::ViewLeaf) = NamedTuple()
function PSE.run!(::ViewLeaf, status, environment, constants, context)
    status.leaf_seen = status.called_input + environment.T
    return nothing
end

struct ViewMiddle{C} <: AbstractLightweight_Target_Middle_ProbeModel
    leaf_capture::C
end
PSE.inputs_(::ViewMiddle) = (local_driver=Default(0.0),)
PSE.outputs_(::ViewMiddle) = (seen=0.0,)
PSE.environment_inputs_(::ViewMiddle) = NamedTuple()
PSE.environment_outputs_(::ViewMiddle) = NamedTuple()
function PSE.run!(model::ViewMiddle, status, environment, constants, context)
    leaf = only(call_targets(context, :leaf))
    leaf.status.called_input = status.local_driver
    run_call!(leaf; publish=true)
    status.seen = leaf.status.leaf_seen
    model.leaf_capture[] = leaf
    return nothing
end

function view_scene(::Type{S}) where {S}
    capture = Ref{Any}()
    leaf_capture = Ref{Any}()
    weather = [
        (date=DateTime(2026, 1, 1) + Hour(i - 1), duration=Hour(1),
         T=10.0 + 10 * i, driver_value=10.0 * i)
        for i in 1:2
    ]
    model = CompositeModel(
        Object(:view_owner; scale=:Scene),
        Object(:view_leaf; scale=:Leaf, parent=:view_owner,
            status=Status(local_driver=-7.0, seen=-999.0));
        applications=(
            ModelSpec(ViewDriver(); name=:view_driver, on=One(id=:view_leaf)),
            ModelSpec(ViewLeaf(); name=:view_leaf, on=One(id=:view_leaf)),
            ModelSpec(ViewMiddle(leaf_capture); name=:view_middle, on=One(id=:view_leaf),
                inputs=(local_driver=One(within=Self(), application=:view_driver, var=:driver),),
                calls=(leaf=One(within=Self(), application=:view_leaf),),
                output_routing=(seen=:stream_only,)),
            ModelSpec(ViewOwner(capture); name=:view_owner, on=One(id=:view_owner),
                inputs=(ready=One(id=:view_leaf, within=SceneScope(),
                    application=:view_driver, var=:driver),),
                calls=(middle=One(id=:view_leaf, within=SceneScope(),
                    application=:view_middle),)),
        ),
        environment=weather,
        type_promotion=Dict(Float64 => S),
    )
    return (; model, capture, leaf_capture)
end

function retained(simulation, application, variable)
    rows = filter(row -> row.application_id === application,
        collect_outputs(simulation, :view_leaf, variable; sink=nothing))
    return sort!(rows; by=row -> row.timestep)
end

@testset "CallTarget preserves application views and captured publication/time" begin
    @test haskey(Base.Docs.meta(PSE), Base.Docs.Binding(PSE, :CallTarget))
    for S in (Float32, Float64)
        @testset "storage=$S" begin
            scene = view_scene(S)
            simulation = run!(scene.model; steps=1, outputs=:all)
            first = only(call_targets(scene.capture[], :middle))
            @test first.object_id == ObjectId(:view_leaf)

            # The renamed input follows its real live reference carrier. The
            # stream-only output belongs to the application view, not canonical
            # storage; substituting canonical Status must fail this check.
            @test first.status.local_driver === S(10)
            @test model_status(scene.model, :view_leaf).local_driver === S(10)
            @test model_status(scene.model, :view_leaf).seen === S(-999)
            run_call!(first; publish=false)
            @test first.status.seen === S(30)
            @test isempty(retained(simulation, :view_middle, :seen))
            @test isempty(retained(simulation, :view_leaf, :leaf_seen))
            rejected_leaf = scene.leaf_capture[]

            run_call!(first; publish=true)
            accepted = deepcopy(retained(simulation, :view_leaf, :leaf_seen))
            @test getproperty.(accepted, :timestep) == [1]
            @test getproperty.(accepted, :value) == S[30]

            # This view captured the unpublished parent permission. A later
            # accepted invocation of the same owner may not change that snapshot.
            # Trial status mutations remain visible; publication is NOT rollback.
            run_call!(rejected_leaf; sampled_environment=(T=99.0,), publish=true)
            @test rejected_leaf.status.leaf_seen === S(109)
            @test isequal(retained(simulation, :view_leaf, :leaf_seen), accepted)

            step!(simulation)
            current = only(call_targets(scene.capture[], :middle))
            run_call!(current; publish=true)
            @test current.status.seen === S(50)
            @test getproperty.(retained(simulation, :view_middle, :seen), :value) == S[30, 50]

            # Inputs are live shared references: the driver is now 20. But this
            # retained view must still use step1's environment T=20 and publish
            # at step1, rather than adopting the newly materialized view's clock.
            run_call!(first; publish=true)
            @test first.status.local_driver === S(20)
            @test first.status.seen === S(40)
            for (application, variable) in ((:view_middle, :seen), (:view_leaf, :leaf_seen))
                rows = retained(simulation, application, variable)
                @test getproperty.(rows, :timestep) == [1, 2]
                @test getproperty.(rows, :value) == S[40, 50]
            end
            @test model_status(scene.model, :view_leaf).local_driver === S(20)
            @test model_status(scene.model, :view_leaf).seen === S(-999)
            @test first.status !== model_status(scene.model, :view_leaf)

            run_call!(current; publish=true)
            @test current.status.seen === S(50)
        end
    end
end

# Opt-in mechanism benchmark only; including this file does NOT run it.
# An external Ref{Any} makes each view escape, matching an actual retained-view
# use rather than letting the compiler remove an unused result. No model runs,
# environment sampling, output publication, or Julia compilation is timed here.
@noinline function escaped_views!(sink::Base.RefValue{Any}, targets, n::Int)
    for _ in 1:n
        sink[] = only(targets)
    end
    return nothing
end

function measure_view_materialization(context, name::Symbol; n::Int=1_000)
    n > 0 || throw(ArgumentError("n must be positive"))
    targets = call_targets(context, name)
    length(targets) == 1 || throw(ArgumentError("benchmark requires one target"))
    sink = Ref{Any}()
    escaped_views!(sink, targets, 8)
    bytes = @allocated escaped_views!(sink, targets, n)
    seconds = @elapsed escaped_views!(sink, targets, n)
    return (samples=n, bytes, bytes_per_view=bytes / n,
        seconds, seconds_per_view=seconds / n, object_id=sink[].object_id)
end

# Qualification still needed after applying the candidate:
# - existing lease/None, newborn/initializer, source-compilation and lifecycle
#   tests, distributed outputs, and the parent-owned MAESPA balance/restart gate;
# - escaped-view microbenchmark is NOT an end-to-end speedup or science verdict;
# - targeted/newborn payload is immutable; do not assume its allocation layout
#   without measuring that cold path in the owning Kaimon session.
end # module LightweightCallTargetChecks
