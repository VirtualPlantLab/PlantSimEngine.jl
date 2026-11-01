module CachedOwnerChecks

using Dates, Test, PlantSimEngine
const PSE=PlantSimEngine
const C=Main.PersistentTightChecks
const E=Main.PersistentFeatureChecks
const D=Main.DirectPlanChecks
const CR=Main.CompiledRegionsExperiment
const F=Main.DirectPlannerFixtures
const M=Main.CachedOwnerMeasurements

export cached_owner_lifecycle_checks, cached_owner_epoch_checks,
    cached_owner_partial_failure_checks, cached_owner_exposure_checks,
    cached_owner_targetless_checks, cached_owner_fallback_checks,
    cached_owner_small_checks, cached_owner_partial_failure_matrix

Base.@nospecializeinfer @noinline function _prepare(model,constants,arm;
    outputs=:all,caches=M.new_caches())
    @nospecialize model constants
    simulation=PSE.run!(model;steps=0,outputs,constants)
    Base.invokelatest(M.lower_candidate!,simulation,arm;caches,count_calls=true)
    return simulation
end

"""Keep every arm's first-/second-tick failure result, including failed controls.

This is diagnostic aggregation: a captured failure stays `passed=false` and is
not relabeled as a passing feature gate. Root can persist the result before a
neutral baseline repair and rerun this same matrix afterwards.
"""
function cached_owner_partial_failure_matrix(;arms=(:persistent,:proof_only,:owner_only,:combined),
    fail_ticks=(1,2),caches=M.new_caches())
    records=Any[]
    for fail_tick in fail_ticks, arm in arms
        try
            result=cached_owner_partial_failure_checks(arm;fail_tick,caches)
            push!(records,(;arm,fail_tick,passed=true,result,error=nothing))
        catch error
            push!(records,(;arm,fail_tick,passed=false,result=nothing,
                error=(type=string(typeof(error)),message=sprint(showerror,error))))
        end
    end
    return (;passed=all(row->row.passed,records),records,
        scope=:independent_per_arm_partial_error_diagnostics_not_a_timing)
end
_report(sim,arm)=M.candidate_report(sim,arm)
_regions(sim,arm)=M.candidate_regions(sim,arm)
_step!(sim)=Base.invokelatest(PSE.step!,sim)
function _pair!(left,right,a,b,tick)
    a.tick[]=b.tick[]=tick
    _step!(left);_step!(right)
    C._science_equal(left,right,a,b)
    return nothing
end

"""Generic values, live references, scientific RNG, growth and removal.

Only the candidate preparation function is injected. Existing scientific
fixtures and state/identity comparisons remain the same as the persistent
prototype. No type-specific numeric state is copied by the harness.
"""
function cached_owner_lifecycle_checks(arm::Symbol;T=Float32,outputs=:all,
    caches=M.new_caches())
    a,b=C._constants(),C._constants()
    left=_prepare(C.persistent_fixture(;T),a,:ordinary_a;outputs,caches)
    right=_prepare(C.persistent_fixture(;T),b,arm;outputs,caches)
    phases=Any[]
    @testset "Cached proof/owner generic lifecycle: $arm $T $outputs" begin
        C._science_equal(left,right,a,b)
        old_left,old_right=F.identities(left.model),F.identities(right.model)
        escaped=PSE.model_status(right.model,2)
        escaped_ref=PSE.refvalue(escaped,:root_value)
        previous=_report(right,arm)
        for (tick,roots) in enumerate((3,4,3,3))
            _pair!(left,right,a,b,tick)
            old_left,old_right=C._identity_parity(old_left,old_right,left,right)
            @test PSE.model_status(right.model,2)===escaped
            @test PSE.refvalue(escaped,:root_value)===escaped_ref
            current=_report(right,arm)
            @test current.executed_numerical_roots-previous.executed_numerical_roots==roots
            @test current.executed_numerical_calls-previous.executed_numerical_calls==roots
            rows=_regions(right,arm)
            growing=only(row for row in rows if row.application===:root)
            @test growing.active && !growing.exposed
            @test Set(growing.row_ids)==Set(PSE.ObjectId.(tick==1 ? (1,2) : tick==2 ? (1,2,3) : (2,3)))
            @test PSE.model_status(right.model,2).root_visits==tick
            if tick>=2
                @test PSE.model_status(right.model,3).root_visits==tick-1
            end
            push!(phases,(;tick,report=current))
            previous=current
        end
    end
    return (;passed=true,arm,T=string(T),outputs,phases,
        scope=:exact_state_history_rng_generic_types_canonical_reference_identity)
end

# Time/publication alone do not detect premature runtime-header rebasing. A cold
# unentered context must retain its old compiled/environment identity, so its
# later ordinary entry synchronizes *all* immediate call edges. Compare relative
# header identity against each independent simulation, without public lookup.
function _header_observation(links,simulation)
    owner(context)=(compiled=context.compiled===simulation.compiled,
        environment=context.environment_bindings===simulation.environment_bindings,
        streams=context.temporal_streams===simulation.temporal_streams,
        retention=context.output_retention===simulation.output_retention)
    edge(collection)=(compiled=collection.compiled===simulation.compiled,
        environment=collection.environment_bindings===simulation.environment_bindings,
        streams=collection.temporal_streams===simulation.temporal_streams,
        retention=collection.output_retention===simulation.output_retention)
    return (root=owner(links.owner.context),middle=edge(links.middle),
        middle_owner=owner(links.middle_owner.context),worker=edge(links.worker),
        worker_owner=owner(links.worker_owner.context))
end
function _observe(left,right)
    observed=E._observe_conditional_pair(left,right)
    headers=Any[]
    for id in keys(observed.left_links)
        expected=_header_observation(observed.left_links[id],left)
        actual=_header_observation(observed.right_links[id],right)
        @test isequal(actual,expected)
        push!(headers,(;id,expected,actual))
    end
    return (;observed...,headers)
end

"""Lookup-only, skipped and unentered nested contexts across consumed refresh.

The default exposes after two *private* steps. Row one's middle has not entered
and its descendant has never been queried. It first enters after exposure,
testing the pending runtime synchronization in addition to stored epoch values.
"""
function cached_owner_epoch_checks(arm::Symbol;inspect_step=2,consume_refresh=true,
    late_unqueried=true,caches=M.new_caches())
    inspect_step in 0:3 || throw(ArgumentError("inspect_step must be 0:3"))
    a,b=C._constants(),C._constants()
    left=_prepare(E.persistent_conditional_fixture(;late_unqueried),a,:ordinary_a;caches)
    right=_prepare(E.persistent_conditional_fixture(;late_unqueried),b,arm;caches)
    observed=nothing;phases=Any[]
    @testset "Cold owners preserve pending nested header epochs: $arm" begin
        inspect_step==0 && (observed=_observe(left,right))
        for tick in 1:3
            if tick==2
                for simulation in (left,right)
                    PSE.register_object!(simulation.model,E._conditional_unit(3;late_unqueried))
                    if consume_refresh
                        PSE.refresh_bindings!(simulation.model)
                        PSE.refresh_environment_bindings!(simulation.model)
                    end
                end
            end
            before=_report(right,arm)
            _pair!(left,right,a,b,tick)
            after=_report(right,arm)
            if tick<=inspect_step
                @test after.executed_numerical_roots-before.executed_numerical_roots==(tick==1 ? 2 : 3)
                @test after.executed_numerical_calls-before.executed_numerical_calls==
                    (late_unqueried ? (1,2,5) : (1,3,6))[tick]
            end
            if tick==inspect_step
                observed=_observe(left,right)
                if late_unqueried && tick==2
                    untouched=only(row for row in observed.observations if row.id==1)
                    @test untouched.expected.middle.time==0.0
                    @test untouched.expected.middle.publication_allowed
                    @test untouched.expected.worker_edge.time==0.0
                    @test untouched.expected.worker_edge.publication_allowed
                end
            elseif observed!==nothing
                for id in keys(observed.left_links)
                    @test isequal(E._conditional_observation(observed.right_links[id]),
                        E._conditional_observation(observed.left_links[id]))
                    @test isequal(_header_observation(observed.right_links[id],right),
                        _header_observation(observed.left_links[id],left))
                end
            end
            push!(phases,(;tick,report=after))
        end
        @test PSE.model_status(right.model,1).worker_visits==(late_unqueried ? 0 : 1)
        @test PSE.model_status(right.model,2).worker_visits==2
        @test PSE.model_status(right.model,3).worker_visits==1
    end
    return (;passed=true,arm,inspect_step,consume_refresh,late_unqueried,phases,
        observations=observed.observations,header_observations=observed.headers,
        scope=:per_call_site_epochs_and_pending_old_compiled_environment_identity)
end

"""Failed middle row preserves entered/unentered owner epochs and retry contract."""
function cached_owner_partial_failure_checks(arm::Symbol;consume_refresh=true,fail_tick=2,
    caches=M.new_caches())
    fail_tick in (1,2) || throw(ArgumentError("Initial partial-error gate supports fail_tick=1 or 2"))
    constants=PSE.PlantMeteo.Constants()
    left=_prepare(D._fixture(false;nobjects=3),constants,:ordinary_a;caches)
    right=_prepare(D._fixture(false;nobjects=3),constants,arm;caches)
    @testset "Cold owner exception cleanup matches ordinary rows: $arm" begin
        for _ in 1:fail_tick-1
            _step!(left);_step!(right);E._science_equal(left,right)
        end
        for simulation in (left,right)
            PSE.model_status(simulation.model,2).fail=true
        end
        expected=try _step!(left);nothing catch error;error end
        actual=try _step!(right);nothing catch error;error end
        @test expected isa ArgumentError
        @test typeof(actual)===typeof(expected)
        @test sprint(showerror,actual)==sprint(showerror,expected)
        @test PSE.current_step(left)==PSE.current_step(right)==fail_tick-1
        E._science_equal(left,right)
        epochs=Any[]
        for id in 1:3
            a,b=E._owner(left,id),E._owner(right,id)
            @test b.context.time==a.context.time
            @test !b.call_context_cache.in_use
            aa,bb=PSE.call_targets(a.context,:middle),PSE.call_targets(b.context,:middle)
            @test isequal(E._metadata(bb),E._metadata(aa))
            @test !only(bb).context_cache.in_use
            push!(epochs,b.context.time)
        end
        @test epochs==(fail_tick==1 ? [1.0,1.0,1.0] : [2.0,2.0,1.0])
        for simulation in (left,right)
            PSE.model_status(simulation.model,2).fail=false
            E._add_spectator!(simulation;consume_refresh)
        end
        expected_retry=try _step!(left);nothing catch error;error end
        actual_retry=try _step!(right);nothing catch error;error end
        @test typeof(actual_retry)===typeof(expected_retry)
        if expected_retry!==nothing
            @test sprint(showerror,actual_retry)==sprint(showerror,expected_retry)
        end
        @test PSE.current_step(left)==PSE.current_step(right)
        E._science_equal(left,right)
        return (;passed=true,arm,consume_refresh,fail_tick,epochs,report=_report(right,arm),
            retry_type=string(typeof(expected_retry)),
            scope=:failed_partial_execution_cleanup_and_post_error_lifecycle)
    end
end

"""Saved public collection/target and canonical refs remain live after growth."""
function cached_owner_exposure_checks(arm::Symbol;caches=M.new_caches())
    a,b=C._constants(),C._constants()
    left=_prepare(C.persistent_fixture(;removal=false),a,:ordinary_a;caches)
    right=_prepare(C.persistent_fixture(;removal=false),b,arm;caches)
    @testset "Cold owner public exposure remains exact: $arm" begin
        left_owner,right_owner=C._root_owner(left,:root),C._root_owner(right,:root)
        saved_left=PSE.call_targets(left_owner.context,:child)
        saved_right=PSE.call_targets(right_owner.context,:child)
        left_view,right_view=only(saved_left),only(saved_right)
        expected_ref=PSE.refvalue(left_view.canonical_status,:child_value)
        actual_ref=PSE.refvalue(right_view.canonical_status,:child_value)
        @test isequal(C._public_metadata(saved_right),C._public_metadata(saved_left))
        for tick in 1:3
            _pair!(left,right,a,b,tick)
            @test isequal(C._public_metadata(saved_right),C._public_metadata(saved_left))
            @test isequal(C._public_target_metadata(right_view),C._public_target_metadata(left_view))
            @test PSE.refvalue(right_view.canonical_status,:child_value)===actual_ref
            @test PSE.refvalue(left_view.canonical_status,:child_value)===expected_ref
            current_left=PSE.call_targets(C._root_owner(left,:root).context,:child)
            current_right=PSE.call_targets(C._root_owner(right,:root).context,:child)
            @test isequal(C._public_metadata(current_right),C._public_metadata(current_left))
            @test only(current_right).canonical_status===PSE.model_status(right.model,1)
            @test all(row->!(row.application===:root && row.active &&
                PSE.ObjectId(1) in row.row_ids),_regions(right,arm))
        end
        return (;passed=true,arm,report=_report(right,arm),
            scope=:saved_public_target_metadata_and_permanent_exposure_fallback)
    end
end

"""Known initially empty application admits its first newborn numerical row."""
function cached_owner_targetless_checks(arm::Symbol;caches=M.new_caches())
    fixture()=begin
        model=C.persistent_fixture(;removal=false)
        PSE.remove_object!(model,1);PSE.remove_object!(model,2)
        model
    end
    a,b=C._constants(),C._constants()
    left=_prepare(fixture(),a,:ordinary_a;caches)
    right=_prepare(fixture(),b,arm;caches)
    phases=Any[]
    @testset "Cached proof/owner targetless newborn application: $arm" begin
        initial=_regions(right,arm)
        @test all(row->row.application!==:root,initial)
        previous=_report(right,arm)
        for tick in 1:3
            if tick==3
                PSE.remove_object!(left.model,3);PSE.remove_object!(right.model,3)
            end
            _pair!(left,right,a,b,tick)
            current=_report(right,arm)
            @test current.executed_numerical_roots-previous.executed_numerical_roots==(tick==2 ? 2 : 1)
            @test current.executed_numerical_calls-previous.executed_numerical_calls==(tick==2 ? 2 : 1)
            if tick==2
                newborn=only(row for row in _regions(right,arm) if row.application===:root)
                @test newborn.active
                @test newborn.last_execution_ids==[PSE.ObjectId(3)]
                @test newborn.last_execution_model_revision==right.compiled.revision
            end
            push!(phases,(;tick,report=current));previous=current
        end
    end
    return (;passed=true,arm,phases,
        scope=:known_zero_target_application_with_existing_scheduled_sentinel)
end

"""Unadmitted evaluate/accept or transient-backend protocols stay ordinary."""
function cached_owner_fallback_checks(arm::Symbol;case=:evaluate_accept,caches=M.new_caches())
    controller=case===:evaluate_accept ? CR.GateCallController() :
        case===:stale_accept ? CR.GateStaleController() :
        case===:backend_override ? CR.GateOverrideController() :
        throw(ArgumentError("Unknown fallback case"))
    left=_prepare(CR.gate_call_fixture(controller),PSE.PlantMeteo.Constants(),:ordinary_a;caches)
    right=_prepare(CR.gate_call_fixture(controller),PSE.PlantMeteo.Constants(),arm;caches)
    @testset "Cached proof/owner unsupported protocol remains ordinary: $arm $case" begin
        for tick in 1:2
            tick==2 && foreach(sim->E._add_spectator!(sim;consume_refresh=true),(left,right))
            _step!(left);_step!(right);E._science_equal(left,right)
            @test _report(right,arm).executed_numerical_roots==0
            @test _report(right,arm).executed_numerical_calls==0
        end
    end
    return (;passed=true,arm,case,report=_report(right,arm),
        scope=:ordinary_evaluation_publication_staleness_or_backend_override)
end

"""A deliberately bounded initial gate, not an implicit large feature matrix."""
function cached_owner_small_checks(arm::Symbol;caches=M.new_caches())
    return (lifecycle=cached_owner_lifecycle_checks(arm;caches),
        epochs=cached_owner_epoch_checks(arm;caches),
        partial_error=cached_owner_partial_failure_checks(arm;caches),
        exposure=cached_owner_exposure_checks(arm;caches))
end

end # module
