module PersistentFeatureChecks

using Dates, Test, PlantSimEngine
const PSE=PlantSimEngine
const D=Main.DirectPlanChecks
const CR=Main.CompiledRegionsExperiment
const F=Main.DirectPlannerFixtures

export persistent_nested_exception_checks, persistent_partial_failure_checks,
    persistent_consumed_exposure_checks, persistent_protocol_fallback_checks,
    persistent_mutable_environment_checks, persistent_many_membership_checks,
    persistent_conditional_epoch_checks, persistent_conditional_fixture

_pt()=getfield(Main,:PersistentTightProgram)
_report(simulation)=Base.invokelatest(_pt().persistent_tight_report,simulation)
Base.@nospecializeinfer @noinline function _candidate(model;constants=PSE.PlantMeteo.Constants())
    @nospecialize model
    return Base.invokelatest(_pt().prepare_persistent_tight,model;
        steps=0,outputs=:all,constants,count_calls=true,state_strategy=:references)
end
Base.@nospecializeinfer @noinline function _reference(model;constants=PSE.PlantMeteo.Constants())
    @nospecialize model
    return PSE.run!(model;steps=0,outputs=:all,constants)
end
Base.@nospecializeinfer @noinline function _step!(simulation)
    @nospecialize simulation
    Base.invokelatest(PSE.step!,simulation)
    return nothing
end
Base.@nospecializeinfer @noinline function _science_equal(left,right)
    @nospecialize left right
    @test isequal(CR.downstream_fingerprint(left),CR.downstream_fingerprint(right))
    @test isequal(F.snapshot(left,:generic),F.snapshot(right,:generic))
    @test isequal(F.scientific_rngs(left.model),F.scientific_rngs(right.model))
    return nothing
end
function _add_spectator!(simulation;consume_refresh=false)
    PSE.register_object!(simulation.model,PSE.Object(:feature_spectator;status=(sentinel=1f0,)))
    if consume_refresh
        PSE.refresh_bindings!(simulation.model)
        PSE.refresh_environment_bindings!(simulation.model)
    end
    return nothing
end
function _owner(simulation,id)
    group=only(group for group in simulation.execution_plan.groups if group.application.id===:root)
    return only(target for batch in group.batches for target in batch.targets if target.object_id==PSE.ObjectId(id))
end
function _metadata(collection)
    target=only(collection)
    return (time=collection.time,publication_allowed=collection.publication_allowed,
        target_time=target.time,target_publication_allowed=target.publication_allowed,
        object_id=target.object_id,application=target.application.id,
        context_time=target.execution_target.context.time,
        context_publication_allowed=target.execution_target.context.publication_allowed)
end

"""Original nested catch/retry kernels remain typed after an unrelated event."""
function persistent_nested_exception_checks(;throw_first=true)
    left=_reference(D._fixture(false;throw_first))
    right=_candidate(D._fixture(false;throw_first))
    reports=Any[]
    @testset "Persistent child frames preserve original catches across refresh" begin
        for tick in 1:2
            tick==2 && foreach(_add_spectator!,(left,right))
            before=_report(right)
            _step!(left);_step!(right)
            _science_equal(left,right)
            after=_report(right)
            @test after.executed_numerical_roots-before.executed_numerical_roots==2
            @test after.executed_numerical_calls-before.executed_numerical_calls==
                (throw_first && tick==1 ? 8 : 4)
            for id in 1:2
                @test PSE.model_status(right.model,id).caught==throw_first
            end
            push!(reports,(tick=tick,report=after))
        end
    end
    return (passed=true,throw_first,reports,
        scope=:original_scientific_exception_frames_before_and_after_refresh)
end

"""Unhandled middle-row failure keeps entered and unentered public epochs."""
function persistent_partial_failure_checks(;consume_refresh=true)
    left=_reference(D._fixture(false;nobjects=3))
    right=_candidate(D._fixture(false;nobjects=3))
    @testset "Persistent failed rows preserve ordinary partial execution" begin
        _step!(left);_step!(right)
        _science_equal(left,right)
        for simulation in (left,right)
            PSE.model_status(simulation.model,2).fail=true
        end
        left_error=try _step!(left);nothing catch error;error end
        right_error=try _step!(right);nothing catch error;error end
        @test left_error isa ArgumentError
        @test typeof(right_error)===typeof(left_error)
        @test sprint(showerror,right_error)==sprint(showerror,left_error)
        @test PSE.current_step(left)==PSE.current_step(right)==1
        _science_equal(left,right)
        epochs=Any[]
        for id in 1:3
            control,actual=_owner(left,id),_owner(right,id)
            @test actual.context.time==control.context.time
            @test !actual.call_context_cache.in_use
            expected=PSE.call_targets(control.context,:middle)
            observed=PSE.call_targets(actual.context,:middle)
            @test isequal(_metadata(observed),_metadata(expected))
            @test !only(observed).context_cache.in_use
            push!(epochs,actual.context.time)
        end
        @test epochs==[2.0,2.0,1.0]
        for simulation in (left,right)
            PSE.model_status(simulation.model,2).fail=false
            _add_spectator!(simulation;consume_refresh)
        end
        # The ordinary scheduler may already have consumed this step before
        # the scientific exception. Match its retry contract rather than
        # requiring a successful continuation that the oracle does not offer.
        left_retry=try _step!(left);nothing catch error;error end
        right_retry=try _step!(right);nothing catch error;error end
        @test (right_retry===nothing)==(left_retry===nothing)
        @test typeof(right_retry)===typeof(left_retry)
        if left_retry!==nothing
            @test sprint(showerror,right_retry)==sprint(showerror,left_retry)
        end
        @test PSE.current_step(left)==PSE.current_step(right)
        _science_equal(left,right)
        return (passed=true,consume_refresh,epochs,report=_report(right),
            retry=(succeeded=left_retry===nothing,
                type=string(typeof(left_retry)),
                message=left_retry===nothing ? nothing : sprint(showerror,left_retry)),
            scope=:failed_frame_cleanup_public_epoch_and_post_failure_lifecycle)
    end
end

"""Saved owners/collections remain exact when both refresh APIs consume an event."""
function persistent_consumed_exposure_checks(;consume_refresh=true)
    left=_reference(D._fixture(false))
    right=_candidate(D._fixture(false))
    @testset "Persistent public exposure survives externally consumed refresh" begin
        _step!(left);_step!(right)
        _science_equal(left,right)
        saved_left=PSE.call_targets(_owner(left,1).context,:middle)
        saved_right=PSE.call_targets(_owner(right,1).context,:middle)
        expected_ref=PSE.refvalue(only(saved_left).canonical_status,:value)
        actual_ref=PSE.refvalue(only(saved_right).canonical_status,:value)
        @test isequal(_metadata(saved_left),_metadata(saved_right))
        for simulation in (left,right)
            _add_spectator!(simulation;consume_refresh)
        end
        for _ in 1:2
            _step!(left);_step!(right)
            _science_equal(left,right)
            @test isequal(_metadata(saved_left),_metadata(saved_right))
            @test PSE.refvalue(only(saved_left).canonical_status,:value)===expected_ref
            @test PSE.refvalue(only(saved_right).canonical_status,:value)===actual_ref
            current_left=PSE.call_targets(_owner(left,1).context,:middle)
            current_right=PSE.call_targets(_owner(right,1).context,:middle)
            @test isequal(_metadata(current_left),_metadata(current_right))
        end
        PSE.run_call!(only(saved_left);sampled_environment=(duration=Hour(1),),publish=true)
        PSE.run_call!(only(saved_right);sampled_environment=(duration=Hour(1),),publish=true)
        _science_equal(left,right)
        @test isequal(_metadata(saved_left),_metadata(saved_right))
        return (passed=true,consume_refresh,report=_report(right),
            scope=:saved_nested_singular_views_and_public_reexecution)
    end
end

"""Original evaluate/accept and backend-override fixtures use the full protocol."""
function persistent_protocol_fallback_checks(;case=:evaluate_accept)
    controller=case===:evaluate_accept ? CR.GateCallController() :
        case===:stale_accept ? CR.GateStaleController() :
        case===:backend_override ? CR.GateOverrideController() :
        throw(ArgumentError("Unknown protocol case"))
    left=_reference(CR.gate_call_fixture(controller))
    right=_candidate(CR.gate_call_fixture(controller))
    @testset "Persistent unsupported call protocols remain ordinary" begin
        for tick in 1:2
            tick==2 && foreach(simulation->_add_spectator!(simulation;consume_refresh=true),(left,right))
            _step!(left);_step!(right)
            _science_equal(left,right)
            @test _report(right).executed_numerical_roots==0
            @test _report(right).executed_numerical_calls==0
        end
        return (passed=true,case,report=_report(right),
            scope=:original_evaluation_staleness_publication_and_transient_backend_override)
    end
end

"""A child samples fresh mutable committed environment before/after refresh."""
function persistent_mutable_environment_checks()
    T=getfield(Main,:TightCallProgramChecks)
    left_fixture=T._environment_fixture(false)
    right_fixture=T._environment_fixture(false)
    left=_reference(left_fixture.model)
    right=_candidate(right_fixture.model)
    reports=Any[]
    @testset "Persistent environment handles never cache mutable sampled values" begin
        for (tick,value) in enumerate((1.0,7.0,11.0))
            if tick==2
                _add_spectator!(left;consume_refresh=true)
                _add_spectator!(right;consume_refresh=true)
            end
            left_fixture.driver[1]=right_fixture.driver[1]=value
            before=_report(right)
            _step!(left);_step!(right)
            _science_equal(left,right)
            after=_report(right)
            @test PSE.model_status(right.model,:unit).value==value
            @test after.executed_numerical_roots-before.executed_numerical_roots==1
            @test after.executed_numerical_calls-before.executed_numerical_calls==1
            push!(reports,(tick=tick,value=value,report=after))
        end
    end
    return (passed=true,reports,scope=:fresh_committed_environment_with_compiled_child_handle)
end

"""Retained singleton-Many results track a second worker after consumed growth."""
function persistent_many_membership_checks(;inspect_before_growth=true)
    Many=getfield(Main,:DirectManyChecks)
    left_constants,right_constants=(capture=Any[],),(capture=Any[],)
    left=_reference(Many._many_fixture(false);constants=left_constants)
    right=_candidate(Many._many_fixture(false);constants=right_constants)
    @testset "Persistent fallback retains live Many result membership" begin
        _step!(left);_step!(right)
        _science_equal(left,right)
        saved_left,saved_right=only(left_constants.capture),only(right_constants.capture)
        if inspect_before_growth
            @test Many._membership(saved_left)==Many._membership(saved_right)==[:worker_1]
        end
        for simulation in (left,right)
            PSE.register_object!(simulation.model,
                PSE.Object(:worker_2;kind=:tracked_worker,status=(value=0.0,)))
            PSE.refresh_bindings!(simulation.model)
            PSE.refresh_environment_bindings!(simulation.model)
        end
        _step!(left);_step!(right)
        _science_equal(left,right)
        @test Many._membership(saved_left)==Many._membership(saved_right)==[:worker_1,:worker_2]
        @test only(left_constants.capture)===saved_left
        @test only(right_constants.capture)===saved_right
        @test PSE.model_status(right.model,:worker_2).value==1.0
        @test _report(right).executed_numerical_roots==0
        @test _report(right).executed_numerical_calls==0
        return (passed=true,inspect_before_growth,report=_report(right),
            scope=:real_retained_many_membership_ordinary_fallback)
    end
end

# A lookup-only edge and a skipped scientific child have different ordinary
# metadata. These kernels never inspect context time/type, retain contexts or
# call results, or mutate lifecycle metadata. The diagnostic observer is below.
PSE.@process "persistent_conditional_root" verbose=false
PSE.@process "persistent_conditional_middle" verbose=false
PSE.@process "persistent_conditional_worker" verbose=false
struct PersistentConditionalRoot <: AbstractPersistent_Conditional_RootModel end
struct PersistentConditionalMiddle <: AbstractPersistent_Conditional_MiddleModel end
struct PersistentConditionalWorker <: AbstractPersistent_Conditional_WorkerModel end
PSE.inputs_(::PersistentConditionalRoot)=(tag=PSE.Required(Int),
    first_lookup=PSE.Required(Int),first_call=PSE.Required(Int))
PSE.inputs_(::PersistentConditionalMiddle)=(tag=PSE.Required(Int),
    descendant_lookup=PSE.Required(Int),descendant_call=PSE.Required(Int))
PSE.inputs_(::PersistentConditionalWorker)=(tag=PSE.Required(Int),)
PSE.outputs_(::PersistentConditionalRoot)=(root_visits=0,)
PSE.outputs_(::PersistentConditionalMiddle)=(middle_visits=0,)
PSE.outputs_(::PersistentConditionalWorker)=(worker_visits=0,value=0f0)
function PSE.run!(::PersistentConditionalRoot,status,environment,constants,context)
    tick=constants.tick[]
    tick>=status.first_lookup && PSE.call_model(context,:middle)
    tick>=status.first_call &&
        PSE.run_call!(context,:middle;sampled_environment=environment,publish=false)
    status.root_visits+=1
    push!(constants.effects,(:root,status.tag,tick))
    return nothing
end
function PSE.run!(::PersistentConditionalMiddle,status,environment,constants,context)
    tick=constants.tick[]
    tick>=status.descendant_lookup && PSE.call_model(context,:worker)
    tick>=status.descendant_call &&
        PSE.run_call!(context,:worker;sampled_environment=environment,publish=false)
    status.middle_visits+=1
    push!(constants.effects,(:middle,status.tag,tick))
    return nothing
end
function PSE.run!(::PersistentConditionalWorker,status,environment,constants,context)
    status.worker_visits+=1
    status.value+=0.5f0
    push!(constants.effects,(:worker,status.tag,constants.tick[]))
    return nothing
end
for T in (PersistentConditionalRoot,PersistentConditionalMiddle,PersistentConditionalWorker)
    @eval Main.NativePBDriver.native_call_effects(::Type{$T})=:fixed_native_calls
    @eval Main.NativePBDriver.direct_status_compatible(::Type{$T})=true
    @eval Main.SharedCallProgram.shared_context_effects(::Type{$T})=:synchronous_borrowed_context
    @eval Main.TightCallProgram.tight_call_effects(::Type{$T})=Main.TightCallProgram._TIGHT_CAPABILITY
end
function _conditional_unit(id;late_unqueried=false)
    first_lookup,first_call,descendant_lookup,descendant_call=
        id==1 ? (late_unqueried ? (1,3,4,4) : (1,2,1,3)) :
        id==2 ? (0,1,1,2) : (3,3,3,3)
    return PSE.Object(id;kind=:persistent_conditional,status=(tag=id,
        first_lookup=first_lookup,first_call=first_call,
        descendant_lookup=descendant_lookup,descendant_call=descendant_call,
        root_visits=0,middle_visits=0,worker_visits=0,value=0f0))
end
function persistent_conditional_fixture(;late_unqueried=false)
    return PSE.CompositeModel(_conditional_unit(1;late_unqueried),_conditional_unit(2;late_unqueried);
        applications=(
            PSE.ModelSpec(PersistentConditionalRoot();name=:root,
                on=PSE.Many(kind=:persistent_conditional),every=Hour(1),calls=(
                    middle=PSE.One(within=PSE.Self(),application=:middle),)),
            PSE.ModelSpec(PersistentConditionalMiddle();name=:middle,
                on=PSE.Many(kind=:persistent_conditional),every=Hour(1),calls=(
                    worker=PSE.One(within=PSE.Self(),application=:worker),)),
            PSE.ModelSpec(PersistentConditionalWorker();name=:worker,
                on=PSE.Many(kind=:persistent_conditional),every=Hour(1))),
        environment=(duration=Hour(1),))
end

# Do not use call_targets or only(CallTargets) to observe a cold edge: public
# lookup itself synchronizes its metadata and could hide the bug under test.
# Materialize the real owner tree without preparing or executing its contexts.
function _raw_collection(owner,name)
    return only(collection for collection in owner.context.calls
        if collection.binding.call===name)
end
function _raw_child_owner(collection)
    batches=PSE._materialize_call_execution_batches!(collection)
    return only(owner for batch in batches for owner in batch.targets)
end
function _conditional_links(owner)
    middle=_raw_collection(owner,:middle)
    middle_owner=_raw_child_owner(middle)
    worker=_raw_collection(middle_owner,:worker)
    worker_owner=_raw_child_owner(worker)
    return (;owner,middle,middle_owner,worker,worker_owner)
end
_owner_epoch(owner)=(time=owner.context.time,
    publication_allowed=owner.context.publication_allowed,
    in_use=owner.call_context_cache.in_use)
_edge_epoch(collection)=(time=collection.time,
    publication_allowed=collection.publication_allowed)
function _conditional_observation(links)
    return (root=_owner_epoch(links.owner),middle_edge=_edge_epoch(links.middle),
        middle=_owner_epoch(links.middle_owner),worker_edge=_edge_epoch(links.worker),
        worker=_owner_epoch(links.worker_owner))
end
function _observe_conditional_pair(left,right)
    left_links=Dict{Int,Any}();right_links=Dict{Int,Any}()
    observations=Any[]
    for object in PSE.model_objects(left.model)
        id=object.id.value
        a=_conditional_links(_owner(left,id))
        b=_conditional_links(_owner(right,id))
        expected,actual=_conditional_observation(a),_conditional_observation(b)
        @test isequal(actual,expected)
        @test !actual.root.in_use && !actual.middle.in_use && !actual.worker.in_use
        left_links[id]=a;right_links[id]=b
        push!(observations,(;id,expected,actual))
    end
    return (;left_links,right_links,observations)
end

"""Observe one private prefix, with lookup-only/skipped children and a newborn.

Run a single inspect_step=0/1/2/3 case; no matrix is implicit. Steps before
inspection remain private, so inspect_step=2/3 validates skipped-node epochs
after actual typed refresh. Observation then intentionally exposes owners and
compares retained metadata during later ordinary fallback. Both edge lookup
metadata and child-owner execution metadata are compared before public lookup
could normalize them. `late_unqueried=true, inspect_step=2` specifically leaves
row one's middle unentered across refresh, exposes it, then first executes it
while its worker edge remains unqueried. This must retain ordinary pending
runtime synchronization rather than merely copying time/publication fields.
There is no timing claim.
"""
function persistent_conditional_epoch_checks(;inspect_step=1,consume_refresh=true,late_unqueried=false)
    inspect_step in 0:3 || throw(ArgumentError("inspect_step must be 0,1,2 or 3"))
    a,b=(tick=Ref(0),effects=Any[]),(tick=Ref(0),effects=Any[])
    left=_reference(persistent_conditional_fixture(;late_unqueried);constants=a)
    right=_candidate(persistent_conditional_fixture(;late_unqueried);constants=b)
    observed=nothing;phases=Any[]
    @testset "Conditional private calls preserve per-node and per-edge epochs" begin
        if inspect_step==0
            observed=_observe_conditional_pair(left,right)
            for row in observed.observations
                @test row.expected.middle.time==row.expected.worker.time==0.0
                @test row.expected.middle.publication_allowed
                @test row.expected.worker.publication_allowed
            end
        end
        for tick in 1:3
            if tick==2
                for simulation in (left,right)
                    PSE.register_object!(simulation.model,_conditional_unit(3;late_unqueried))
                    if consume_refresh
                        PSE.refresh_bindings!(simulation.model)
                        PSE.refresh_environment_bindings!(simulation.model)
                    end
                end
            end
            a.tick[]=b.tick[]=tick
            before=_report(right)
            _step!(left);_step!(right)
            _science_equal(left,right)
            @test isequal(a.effects,b.effects)
            after=_report(right)
            if tick<=inspect_step
                @test after.executed_numerical_roots-before.executed_numerical_roots==(tick==1 ? 2 : 3)
                @test after.executed_numerical_calls-before.executed_numerical_calls==
                    (late_unqueried ? (1,2,5) : (1,3,6))[tick]
            end
            if tick==1
                @test PSE.model_status(right.model,1).middle_visits==0
                @test all(id->PSE.model_status(right.model,id).worker_visits==0,1:2)
            end
            if tick==inspect_step
                observed=_observe_conditional_pair(left,right)
                if late_unqueried && tick==2
                    untouched=only(row for row in observed.observations if row.id==1)
                    @test untouched.expected.middle.time==0.0
                    @test untouched.expected.middle.publication_allowed
                    @test untouched.expected.worker_edge.time==0.0
                    @test untouched.expected.worker_edge.publication_allowed
                end
            elseif observed!==nothing
                for id in keys(observed.left_links)
                    @test isequal(_conditional_observation(observed.right_links[id]),
                        _conditional_observation(observed.left_links[id]))
                end
            end
            push!(phases,(;tick,report=after))
        end
        @test PSE.model_status(right.model,1).worker_visits==(late_unqueried ? 0 : 1)
        @test PSE.model_status(right.model,2).worker_visits==2
        @test PSE.model_status(right.model,3).worker_visits==1
        return (passed=true,inspect_step,consume_refresh,late_unqueried,phases,
            observations=observed.observations,
            scope=:original_conditional_call_and_lookup_epochs_before_materialization,
            actual_private_prefix_steps=inspect_step,benchmark_claim=false)
    end
end

end # module
