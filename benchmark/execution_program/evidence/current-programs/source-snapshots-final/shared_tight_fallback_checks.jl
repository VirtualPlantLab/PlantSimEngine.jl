module SharedTightFallbackChecks

using Dates, Test, PlantSimEngine
const PSE=PlantSimEngine
const Native=Main.NativePBDriver
const Shared=Main.SharedCallProgram
const Tight=Main.TightCallProgram
const CR=Main.CompiledRegionsExperiment

export borrowed_many_probe, borrowed_many_checks, borrowed_retained_probe,
    borrowed_retained_checks, borrowed_fallback_checks

# These fixture types deliberately opt into BOTH shared-call capabilities.
# A singleton Many must therefore be refused for its tracking contract, rather
# than accidentally being refused because its kernel lacks a capability.
PSE.@process "audit_borrowed_many_controller" verbose=false
PSE.@process "audit_borrowed_many_worker" verbose=false
struct BorrowedManyController <: AbstractAudit_Borrowed_Many_ControllerModel end
struct BorrowedManyWorker <: AbstractAudit_Borrowed_Many_WorkerModel end
PSE.inputs_(::BorrowedManyController)=NamedTuple()
PSE.outputs_(::BorrowedManyController)=(visits=0,)
PSE.inputs_(::BorrowedManyWorker)=NamedTuple()
PSE.outputs_(::BorrowedManyWorker)=(value=0.0,)
function PSE.run!(::BorrowedManyController,status,environment,constants,context)
    targets=PSE.run_call!(context,:workers;publish=true)
    isempty(constants.capture) && push!(constants.capture,targets)
    status.visits+=1
    return nothing
end
function PSE.run!(::BorrowedManyWorker,status,environment,constants,context)
    status.value+=1.0
    return nothing
end

PSE.@process "audit_borrowed_retained_controller" verbose=false
PSE.@process "audit_borrowed_retained_worker" verbose=false
struct BorrowedRetainedController <: AbstractAudit_Borrowed_Retained_ControllerModel end
struct BorrowedRetainedWorker <: AbstractAudit_Borrowed_Retained_WorkerModel end
PSE.inputs_(::BorrowedRetainedController)=NamedTuple()
PSE.outputs_(::BorrowedRetainedController)=(phase=0,observed=0.0,captured_time=0.0)
PSE.inputs_(::BorrowedRetainedWorker)=NamedTuple()
PSE.outputs_(::BorrowedRetainedWorker)=(value=0.0,)
PSE.dep(::BorrowedRetainedController)=(worker=PSE.Call(PSE.One(
    within=PSE.Self(),process=:audit_borrowed_retained_worker)),)
function PSE.run!(::BorrowedRetainedWorker,status,environment,constants,context)
    status.value+=environment
    return nothing
end
function PSE.run!(::BorrowedRetainedController,status,environment,constants,context)
    targets=PSE.run_call!(context,:worker;sampled_environment=2.0,publish=false)
    if status.phase==0
        push!(constants.capture,targets)
    else
        target=only(only(constants.capture))
        status.captured_time=target.time
        cell=PSE.refvalue(target.status,:value)
        cell[]=cell[]+3.0
        PSE.run_call!(target;sampled_environment=4.0,publish=true)
        status.observed=target.status.value
    end
    status.phase+=1
    return nothing
end

# Contexts are borrowed synchronously; only genuine collections/cells escape.
# The stronger Tight promise cannot be made: controllers retain call returns
# and use publication/public target operations. It is explicitly full protocol.
for T in (BorrowedManyController,BorrowedManyWorker,
    BorrowedRetainedController,BorrowedRetainedWorker)
    @eval Native.native_call_effects(::Type{$T})=:fixed_native_calls
    @eval Shared.shared_context_effects(::Type{$T})=:synchronous_borrowed_context
    @eval Tight.tight_call_effects(::Type{$T})=:full_protocol
end

function _many_fixture(native)
    return PSE.CompositeModel(
        PSE.Object(:owner;status=(visits=0,)),
        PSE.Object(:worker_1;kind=:audit_tracked_worker,status=(value=0.0,));
        applications=(
            PSE.ModelSpec(BorrowedManyController();name=:controller,
                on=PSE.One(id=:owner),every=Hour(1),calls=(
                    workers=PSE.Many(kind=:audit_tracked_worker,within=PSE.SceneScope(),
                        application=:worker),)),
            PSE.ModelSpec(BorrowedManyWorker();name=:worker,
                on=PSE.Many(kind=:audit_tracked_worker),every=Hour(1)),
        ),environment=(duration=Hour(1),),
        status_storage=native ? PSE.NativeColumnStorage() : nothing)
end

function _retained_fixture(native)
    return PSE.CompositeModel(PSE.Object(:unit;
        status=(value=0.0,phase=0,observed=0.0,captured_time=0.0));
        applications=(
            PSE.ModelSpec(BorrowedRetainedController();name=:controller,
                on=PSE.One(id=:unit),every=Hour(1)),
            PSE.ModelSpec(BorrowedRetainedWorker();name=:worker,
                on=PSE.One(id=:unit),every=Hour(1)),
        ),environment=(duration=Hour(1),),
        status_storage=native ? PSE.NativeColumnStorage() : nothing)
end

function _prepare(backend,model,native,constants)
    strategy=native ? :native : :references
    if backend===:shared
        return Shared.prepare_shared_calls(model;steps=0,outputs=:all,
            state_strategy=strategy,constants)
    elseif backend===:tight
        return Tight.prepare_tight_calls(model;steps=0,outputs=:all,
            state_strategy=strategy,constants,count_calls=true)
    end
    throw(ArgumentError("Unknown fallback-check backend: $backend"))
end
_report(::Val{:shared},simulation)=Shared.shared_call_report(simulation)
_report(::Val{:tight},simulation)=Tight.tight_call_report(simulation)
_report(backend,simulation)=_report(Val(backend),simulation)
_shared_reasons(::Val{:shared},report)=report.reasons
_shared_reasons(::Val{:tight},report)=report.shared_reasons
_shared_roots(::Val{:shared},report)=report.executed_numerical_roots
_shared_roots(::Val{:tight},report)=report.full_shared_numerical_roots
_shared_calls(::Val{:shared},report)=report.executed_numerical_calls
_shared_calls(::Val{:tight},report)=report.full_shared_numerical_calls
_same(left,right)=isequal(CR.downstream_fingerprint(left),CR.downstream_fingerprint(right))
_membership(targets)=sort!([target.object_id.value for target in targets];by=string)
_canonical(targets,simulation)=all(target->
    PSE.refvalue(target.status,:value)===
        PSE.refvalue(PSE.model_status(simulation.model,target.object_id),:value),targets)

function _consume!(simulation,consume_refresh)
    if consume_refresh
        PSE.refresh_bindings!(simulation.model)
        PSE.refresh_environment_bindings!(simulation.model)
    end
    return nothing
end

"""
One cheap case. The first genuine singleton-Many return survives growth. Its
membership must track the added worker even when external callers consume both
refresh caches before the simulation resumes. No scientific work is expensive.
"""
function borrowed_many_probe(;backend=:shared,native=true,
    inspect_before_growth=false,consume_refresh=true)
    left,right=(capture=Any[],),(capture=Any[],)
    reference=PSE.run!(_many_fixture(false);steps=0,outputs=:all,constants=left)
    candidate=_prepare(backend,_many_fixture(native),native,right)
    prepared=_report(backend,candidate)
    guarded=any(reason->reason.reason===:tracked_many_call_boundary,
        _shared_reasons(Val(backend),prepared))
    PSE.step!(reference);PSE.step!(candidate)
    initial_same=_same(candidate,reference)
    saved_left,saved_right=only(left.capture),only(right.capture)
    are_collections=saved_left isa PSE.CallTargets && saved_right isa PSE.CallTargets
    initial_left=inspect_before_growth ? _membership(saved_left) : nothing
    initial_right=inspect_before_growth ? _membership(saved_right) : nothing
    for simulation in (reference,candidate)
        PSE.register_object!(simulation.model,PSE.Object(:worker_2;
            kind=:audit_tracked_worker,status=(value=0.0,)))
        _consume!(simulation,consume_refresh)
    end
    PSE.step!(reference);PSE.step!(candidate)
    same_after_growth=_same(candidate,reference)
    left_membership,right_membership=_membership(saved_left),_membership(saved_right)
    canonical=_canonical(saved_left,reference) && _canonical(saved_right,candidate)
    retained_identity=only(left.capture)===saved_left && only(right.capture)===saved_right
    newborn_left=PSE.model_status(reference.model,:worker_2).value
    newborn_right=PSE.model_status(candidate.model,:worker_2).value
    # The retained collection remains executable and publishes all current
    # targets, including the newborn; this also checks retained stream coverage.
    for target in saved_left
        PSE.run_call!(target;publish=true)
    end
    for target in saved_right
        PSE.run_call!(target;publish=true)
    end
    return (;backend,native,inspect_before_growth,consume_refresh,prepared,guarded,
        are_collections,initial_same,initial_left,initial_right,same_after_growth,
        left_membership,right_membership,canonical,retained_identity,newborn_left,newborn_right,
        same_after_saved_publication=_same(candidate,reference),
        final_newborn_left=PSE.model_status(reference.model,:worker_2).value,
        final_newborn_right=PSE.model_status(candidate.model,:worker_2).value,
        report=_report(backend,candidate))
end

function borrowed_many_checks()
    reports=Any[]
    @testset "Explicit borrowed capability preserves retained singleton Many through growth" begin
        for backend in (:shared,:tight),native in (false,true),
            inspect_before_growth in (false,true),consume_refresh in (false,true)
            result=borrowed_many_probe(;backend,native,inspect_before_growth,consume_refresh)
            @test result.guarded
            @test result.are_collections
            @test result.initial_same
            if inspect_before_growth
                @test result.initial_left==result.initial_right==[:worker_1]
            end
            @test result.left_membership==result.right_membership==[:worker_1,:worker_2]
            @test result.same_after_growth
            @test result.retained_identity
            @test result.canonical
            @test result.newborn_left==result.newborn_right==1.0
            @test result.same_after_saved_publication
            @test result.final_newborn_left==result.final_newborn_right==2.0
            @test _shared_roots(Val(backend),result.report)==0
            @test _shared_calls(Val(backend),result.report)==0
            if backend===:shared
                @test result.prepared.program_cohorts==0
            else
                @test result.prepared.tight_batches_prepared==0
                @test result.report.executed_numerical_roots==0
                @test result.report.executed_numerical_calls==0
            end
            push!(reports,result)
        end
    end
    return (;passed=true,reports)
end

"""
An explicitly borrowed controller retains a real singular result and uses the
public protocol later. It must initially execute Shared, including when prepared
by Tight, then retire its original owners before unrelated structural refresh.
"""
function borrowed_retained_probe(;backend=:shared,native=true,
    inspect_before_growth=false,consume_refresh=true)
    left,right=(capture=Any[],),(capture=Any[],)
    reference=PSE.run!(_retained_fixture(false);steps=0,outputs=:all,constants=left)
    candidate=_prepare(backend,_retained_fixture(native),native,right)
    prepared=_report(backend,candidate)
    canonical=PSE.model_status(candidate.model,:unit)
    original_cell=PSE.refvalue(canonical,:value)
    PSE.step!(reference);PSE.step!(candidate)
    initial_same=_same(candidate,reference)
    after_first=_report(backend,candidate)
    saved_left,saved_right=only(left.capture),only(right.capture)
    are_collections=saved_left isa PSE.CallTargets && saved_right isa PSE.CallTargets
    if inspect_before_growth
        only(saved_left);only(saved_right)
    end
    for simulation in (reference,candidate)
        PSE.register_object!(simulation.model,PSE.Object(:spectator;status=(sentinel=1.0f0,)))
        _consume!(simulation,consume_refresh)
    end
    PSE.step!(reference);PSE.step!(candidate)
    same_after_growth=_same(candidate,reference)
    retained_identity=only(left.capture)===saved_left && only(right.capture)===saved_right
    target_left,target_right=only(saved_left),only(saved_right)
    left_time,right_time=target_left.time,target_right.time
    left_captured=PSE.model_status(reference.model,:unit).captured_time
    right_captured=PSE.model_status(candidate.model,:unit).captured_time
    canonical_identity=PSE.model_status(candidate.model,:unit)===canonical &&
        PSE.refvalue(canonical,:value)===original_cell &&
        PSE.refvalue(target_right.status,:value)===original_cell
    value_after_growth=PSE.model_status(candidate.model,:unit).value
    PSE.run_call!(target_left;sampled_environment=5.0,publish=true)
    PSE.run_call!(target_right;sampled_environment=5.0,publish=true)
    return (;backend,native,inspect_before_growth,consume_refresh,prepared,after_first,
        initial_same,are_collections,same_after_growth,retained_identity,
        left_time,right_time,left_captured,right_captured,canonical_identity,value_after_growth,
        same_after_saved_publication=_same(candidate,reference),
        final_value=PSE.model_status(candidate.model,:unit).value,
        report=_report(backend,candidate))
end

function borrowed_retained_checks()
    reports=Any[]
    @testset "Retained borrowed One uses Shared full protocol and retires live owners" begin
        for backend in (:shared,:tight),native in (false,true),
            inspect_before_growth in (false,true),consume_refresh in (false,true)
            result=borrowed_retained_probe(;backend,native,inspect_before_growth,consume_refresh)
            @test result.initial_same
            @test result.are_collections
            @test _shared_roots(Val(backend),result.after_first)==1
            @test _shared_calls(Val(backend),result.after_first)==1
            @test result.same_after_growth
            @test result.retained_identity
            @test result.left_time==result.right_time==2.0
            @test result.left_captured==result.right_captured==2.0
            @test result.canonical_identity
            @test result.value_after_growth==11.0
            @test result.same_after_saved_publication
            @test result.final_value==16.0
            @test _shared_roots(Val(backend),result.report)==1
            @test _shared_calls(Val(backend),result.report)==1
            if backend===:shared
                @test result.prepared.program_cohorts==1
                @test result.report.live_shared_batches==0
            else
                @test result.prepared.tight_batches_prepared==0
                @test any(reason->reason.reason===:full_call_protocol_required,result.prepared.reasons)
                @test result.report.executed_numerical_roots==0
                @test result.report.executed_numerical_calls==0
            end
            push!(reports,result)
        end
    end
    return (;passed=true,reports)
end

function borrowed_fallback_checks()
    many=borrowed_many_checks()
    retained=borrowed_retained_checks()
    return (;passed=true,many,retained)
end

end
