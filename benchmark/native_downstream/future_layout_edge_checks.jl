module FutureLayoutEdgeChecks

using Dates, Random, Test, PlantSimEngine
const PSE=PlantSimEngine
const Fixtures=Main.FutureLayoutFixtures
const Measurements=Main.FutureLayoutMeasurements
const Future=Main.FutureLayouts

export many_future_layout_checks, future_shared_storage_rejection_checks

PSE.@process "future_edge_creator" verbose=false
PSE.@process "future_edge_source" verbose=false
PSE.@process "future_edge_consumer" verbose=false

struct EdgeCreator <: AbstractFuture_Edge_CreatorModel
    probe::Fixtures.KernelProbe
end
struct EdgeSource <: AbstractFuture_Edge_SourceModel
    probe::Fixtures.KernelProbe
end
struct EdgeConsumer <: AbstractFuture_Edge_ConsumerModel
    probe::Fixtures.KernelProbe
end
PSE.inputs_(::EdgeCreator)=NamedTuple()
PSE.outputs_(::EdgeCreator)=(tick=0,created=0)
PSE.inputs_(::EdgeSource)=NamedTuple()
PSE.outputs_(::EdgeSource)=(signal=0.0f0,visits=0)
PSE.inputs_(::EdgeConsumer)=(signals=PSE.Required(Vector{Float32}),)
PSE.outputs_(::EdgeConsumer)=(total=0.0f0,seen_ids=PSE.ObjectId[],seen_values=Float32[])
_source_object(id)=PSE.Object(id;kind=:future_edge_source,parent=0,
    status=(signal=0.0f0,visits=0))

function PSE.run!(model::EdgeCreator,status,environment,constants,context)
    model.probe.creator_calls+=1
    Fixtures._observe!(model.probe,model,status,environment,constants,context)
    status.tick+=1
    # The consumer genuinely executes once with no source, then with one/two.
    if status.tick>1 && status.created<2
        status.created+=1
        PSE.register_object!(PSE.runtime_model(context),_source_object(status.created))
    end
    return nothing
end
function PSE.run!(model::EdgeSource,status,environment,constants,context)
    model.probe.worker_calls+=1
    Fixtures._observe!(model.probe,model,status,environment,constants,context)
    status.signal+=1.0f0
    status.visits+=1
    return nothing
end
function PSE.run!(model::EdgeConsumer,status,environment,constants,context)
    model.probe.child_calls+=1
    Fixtures._observe!(model.probe,model,status,environment,constants,context)
    bound=PSE.bound_input(context,:signals)
    status.total=sum(bound;init=0.0f0)
    status.seen_ids=collect(PSE.object_ids(bound))
    status.seen_values=collect(bound)
    return nothing
end

Base.@nospecializeinfer @noinline function _many_fixture(;nfuture=0,record_types=false)
    probe=Fixtures.KernelProbe(record_types)
    environment=(duration=Hour(1),)
    model=PSE.CompositeModel(PSE.Object(0),PSE.Object(100;parent=0),
        (_source_object(id) for id in 1:nfuture)...;
        applications=(
            PSE.ModelSpec(EdgeCreator(probe);name=:edge_create,on=PSE.One(id=0),every=Hour(1)),
            PSE.ModelSpec(EdgeSource(probe);name=:edge_source,
                on=PSE.Many(kind=:future_edge_source),every=Hour(1)),
            PSE.ModelSpec(EdgeConsumer(probe);name=:edge_consume,on=PSE.One(id=100),
                every=Hour(1),inputs=(signals=PSE.Many(kind=:future_edge_source,
                    within=PSE.SceneScope(),application=:edge_source,var=:signal),)),
        ),environment)
    return (;model,probe,environment)
end

Base.@nospecializeinfer @noinline function _prepare_many(arm,outputs,max_requests,status_max_requests)
    fixture=Base.invokelatest(_many_fixture;record_types=true)
    bounded=arm in (:bounded_preparation,:combined)
    bounded && Base.invokelatest(getfield(Main,:BoundedPreparation).enable_bounded_preparation!,fixture.model)
    simulation=Base.invokelatest(PSE.run!,fixture.model;steps=0,outputs)
    before=Base.invokelatest(Fixtures.fixture_guard,fixture)
    identities=Base.invokelatest(Measurements._canonical_identities,fixture.model)
    rng_before=Base.invokelatest(Fixtures.task_rng_state)
    catalogue=nothing
    if arm in (:future_precompile,:combined)
        types=Dict{Any,Any}(name=>typeof(fixture.environment)
            for name in (:edge_create,:edge_source,:edge_consume))
        populated=Future.FutureArchetype(:populated_many,
            ()->Base.invokelatest(_many_fixture;nfuture=2).model;environment_types=types)
        empty=Future.FutureArchetype(:empty_many,
            ()->Base.invokelatest(_many_fixture;nfuture=0).model;environment_types=types)
        catalogue=Base.invokelatest(Future.precompile_future_layouts!,simulation,
            Any[populated,empty];bounded,outputs,max_requests,status_max_requests)
    end
    @test Base.invokelatest(Fixtures.fixture_guard,fixture)==before
    @test Base.invokelatest(Fixtures.task_rng_state)==rng_before
    @test Measurements._same_canonical_identities(identities,
        Base.invokelatest(Measurements._canonical_identities,fixture.model))
    return Dict{Symbol,Any}(:fixture=>fixture,:simulation=>simulation,:catalogue=>catalogue)
end

Base.@nospecializeinfer @noinline function _assert_many(state,step)
    @nospecialize state
    simulation=state[:simulation]
    canonical=PSE.model_status(simulation.model,100)
    view=simulation.compiled.status_views_by_target[(:edge_consume,PSE.ObjectId(100))]
    bound=view.bound_inputs.signals
    count=max(0,step-1)
    expected_ids=PSE.ObjectId[PSE.ObjectId(id) for id in 1:count]
    expected_values=Float32[step-id for id in 1:count]
    @test collect(PSE.object_ids(bound))==expected_ids
    @test collect(bound)==expected_values
    @test bound.values===canonical.signals
    @test length(bound)==count
    @test step<=1 ? eltype(bound)===Any : eltype(bound)===Float32
    if step>0
        @test canonical.seen_ids==expected_ids
        @test canonical.seen_values==expected_values
        @test canonical.total===sum(expected_values;init=0.0f0)
    end
    for (index,id) in enumerate(expected_ids)
        source=PSE.model_status(simulation.model,id)
        @test source.signal===expected_values[index]
        @test PSE.refvalue(source,:signal)===parent(bound.values)[index]
    end
    return (;ids=expected_ids,values=expected_values,
        carrier_type=string(typeof(bound.values)),element_type=string(eltype(bound)))
end

"""Executed empty→one→two Many input, exact aligned IDs and live source cells.

Run one arm at a time, starting with :future_precompile. The ordinary executor
is the control. Both disposable archetypes remain at step zero. Finite status
and actual kernel-entry type matches are distinct from precompile cache hits.
This optional file is deliberately absent from the frozen cold loader.
"""
Base.@nospecializeinfer @noinline function many_future_layout_checks(;
    arm::Symbol=:future_precompile,outputs=:all,max_requests::Int=20,status_max_requests::Int=8)
    arm in Measurements.ARMS || throw(ArgumentError("Unknown arm: $arm"))
    reports=Dict{Symbol,Any}()
    @testset "Future status layouts with an empty-to-typed Many carrier" begin
        control=Base.invokelatest(_prepare_many,:reference_executor,outputs,0,0)
        candidate=Base.invokelatest(_prepare_many,arm,outputs,max_requests,status_max_requests)
        for step in 0:3
            if step>0
                Base.invokelatest(PSE.step!,control[:simulation])
                Base.invokelatest(PSE.step!,candidate[:simulation])
            end
            left=Base.invokelatest(_assert_many,control,step)
            right=Base.invokelatest(_assert_many,candidate,step)
            @test left==right
            @test isequal(Base.invokelatest(Fixtures.portable_snapshot,candidate[:simulation]),
                Base.invokelatest(Fixtures.portable_snapshot,control[:simulation]))
        end
        calls=candidate[:fixture].probe
        @test calls.creator_calls==3
        @test calls.worker_calls==3
        @test calls.child_calls==3
        catalogue=candidate[:catalogue]
        if catalogue!==nothing
            report=Base.invokelatest(Future.future_layout_report,catalogue)
            @test :edge_source in report.targetless_before
            @test report.total_requests_attempted>0
            @test report.total_requests_accepted>0
            @test any(result->result.label===:bound_many_constructor && result.accepted,
                catalogue.status_results)
            matches=Base.invokelatest(Future.match_future_status_layouts,catalogue,
                candidate[:simulation])
            @test matches.observed>0
            @test matches.missed==0
            observed=Base.invokelatest(Fixtures.generic_observations,candidate[:fixture])
            kernel_matches=Base.invokelatest(Future.match_observed_kernel_layouts,catalogue,observed)
            @test kernel_matches.observations==9
            @test kernel_matches.all_requested
            # Finite request budget may select only one scene's scheduler;
            # actual matching requests and accepted matches remain explicit.
            @test kernel_matches.by_application[:edge_source].accepted_matches==3
            reports[:future]=report
            reports[:status_matches]=matches
            reports[:actual_kernel_matches]=kernel_matches
        end
        if arm in (:bounded_preparation,:combined)
            bounded=Base.invokelatest(getfield(Main,:BoundedPreparation).bounded_preparation_report,
                candidate[:simulation])
            @test bounded.scene_entries>0
            @test bounded.metadata_symbol_tables>0
            reports[:bounded]=bounded
        end
    end
    return (;passed=true,arm,outputs,reports)
end

Base.@nospecializeinfer @noinline function _fresh_shared_model(fixture,kind)
    @nospecialize fixture
    fresh=Base.invokelatest(Fixtures._generic_model;nfuture=2)
    backend=kind===:backend ? fixture.environment : fresh.environment
    root=if kind===:reference
        reference=PSE.refvalue(PSE.model_status(fixture.model,0),:births)
        # The Ref-tuple Status constructor preserves this exact cell while
        # allocating a distinct Status identity and a distinct CompositeModel.
        PSE.Object(0;status=PSE.Status((births=reference,)))
    else
        PSE.Object(0)
    end
    model=PSE.CompositeModel(root,Fixtures._unit(1),Fixtures._unit(2);
        applications=fresh.model.applications,environment=backend)
    @test model!==fixture.model
    if kind===:backend
        @test model.environment===fixture.environment
    else
        @test PSE.model_status(model,0)!==PSE.model_status(fixture.model,0)
        @test PSE.refvalue(PSE.model_status(model,0),:births)===
            PSE.refvalue(PSE.model_status(fixture.model,0),:births)
    end
    return model
end

"""Reject a fresh model sharing only a live backend or canonical scalar Ref.

The bad builder also seeds/draws the default RNG. Both task RNG states, exact
live canonical identities, values/history/topology and probe state must survive
the rejected discovery. No scientific kernel is executed by either builder.
"""
Base.@nospecializeinfer @noinline function future_shared_storage_rejection_checks()
    @testset "Independent future model must not share live scientific storage" begin
        for kind in (:backend,:reference)
            fixture=Base.invokelatest(Fixtures.generic_future_fixture)
            simulation=Base.invokelatest(PSE.run!,fixture.model;steps=0,outputs=:all)
            before=Base.invokelatest(Fixtures.fixture_guard,fixture)
            snapshot=Base.invokelatest(Fixtures.portable_snapshot,simulation)
            identities=Base.invokelatest(Measurements._canonical_identities,fixture.model)
            rng_before=Base.invokelatest(Fixtures.task_rng_state)
            builder=()->begin
                Random.seed!(97531)
                rand(Random.default_rng(),UInt64)
                Base.invokelatest(_fresh_shared_model,fixture,kind)
            end
            archetype=Future.FutureArchetype(Symbol(:shared_,kind),builder;
                environment_types=fixture.environment_types)
            @test_throws ArgumentError Base.invokelatest(Future.precompile_future_layouts!,
                simulation,archetype;max_requests=0,status_max_requests=0,include_calls=false)
            @test Base.invokelatest(Fixtures.task_rng_state)==rng_before
            @test Base.invokelatest(Fixtures.fixture_guard,fixture)==before
            @test isequal(Base.invokelatest(Fixtures.portable_snapshot,simulation),snapshot)
            @test Measurements._same_canonical_identities(identities,
                Base.invokelatest(Measurements._canonical_identities,fixture.model))
            @test PSE.current_step(simulation)==0
        end
    end
    return (;passed=true,rejected=(:shared_backend,:shared_canonical_reference))
end

end # module
