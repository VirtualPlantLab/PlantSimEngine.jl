module SharedCallProgramChecks

using Dates, Test, PlantSimEngine
const PSE=PlantSimEngine
const Shared=Main.SharedCallProgram
const Native=Main.NativePBDriver
const CR=Main.CompiledRegionsExperiment
const DirectChecks=Main.DirectCallCompilerChecks
const CallChecks=Main.CallGrowthChecks

export shared_pb_checks, shared_nested_throw_probe, shared_nested_throw_checks,
    shared_retained_checks, shared_conditional_checks, shared_root_skipped_checks, shared_fallback_checks,
    shared_all_checks

# These fixture kernels are read here as an explicit source audit. Their
# contexts are synchronous borrows; retaining a true collection or scientific
# cell is deliberately allowed by the separate capability.
for T in (DirectChecks.DirectRetainedController,DirectChecks.DirectRetainedWorker,
    CallChecks.TransitiveRoot,CallChecks.TransitiveMiddle,CallChecks.TransitiveLeaf)
    @eval Shared.shared_context_effects(::Type{$T})=:synchronous_borrowed_context
end

function shared_pb_checks(;nobjects=2,steps=2)
    reports=Any[]
    @testset "Actual shared PB call program: original kernels and canonical rows" begin
        for native in (false,true),outputs in (:none,:all)
            reference_fixture=Native.pb_native_fixture(;native=false,nobjects,steps)
            fixture=Native.pb_native_fixture(;native,nobjects,steps)
            reference=PSE.run!(reference_fixture.model;steps=0,outputs)
            candidate=Shared.prepare_shared_calls(fixture.model;steps=0,outputs,
                state_strategy=native ? :native : :references)
            prepared=Shared.shared_call_report(candidate)
            @test prepared.immutable_program_nodes==3
            @test prepared.shared_numerical_contexts==3
            @test prepared.program_cohorts==1
            @test prepared.row_lease_slots==nobjects
            @test prepared.lazy_public_wrappers==0
            @test prepared.constructed_rich_targets==0
            @test prepared.lazy_materializations==0
            canonical=PSE.model_status(fixture.model,1)
            escaped=PSE.refvalue(canonical,:Ra_SW_f)
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            for step in 1:steps
                PSE.step!(reference)
                PSE.step!(candidate)
                @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
                report=Shared.shared_call_report(candidate)
                @test report.shared_numerical_contexts==3
                @test report.lazy_public_wrappers==2*nobjects
                @test report.constructed_rich_targets==0
                @test report.lazy_materializations==0
            end
            @test PSE.model_status(fixture.model,1)===canonical
            @test PSE.refvalue(canonical,:Ra_SW_f)===escaped
            report=Shared.shared_call_report(candidate)
            @test report.executed_numerical_roots==nobjects*steps
            @test report.executed_numerical_calls>0
            @test report.typed_model_lookups>0
            @test report.fallback_calls==0
            @test (report.executed_native_column_fields>0)===native
            @test report.shared_numerical_contexts<nobjects*3
            push!(reports,(;native,outputs,prepared,report))
        end
    end
    return (;passed=true,reports)
end

function shared_nested_throw_probe(;native=true,publish=false,throw_first=true)
    reference=PSE.run!(CallChecks._transitive_fixture(false;publish,throw_first);
        steps=0,outputs=:all)
    candidate=Shared.prepare_shared_calls(CallChecks._transitive_fixture(native;publish,throw_first);
        steps=0,outputs=:all,state_strategy=native ? :native : :references)
    parity=Bool[]
    for _ in 1:2
        PSE.step!(reference)
        PSE.step!(candidate)
        push!(parity,isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference)))
    end
    function clean(frame)
        frame.in_use_row==0 && all(owner->owner===nothing || !owner.call_context_cache.in_use,frame.owners) &&
            all(entry->clean(entry.frame),values(frame.context.calls.entries))
    end
    cleaned=all(batch->!(batch isa Shared.SharedProgramBatch) ||
        (batch.frame.context.calls.state.row==0 &&
         all(lease->!lease.running,batch.frame.context.calls.state.leases) && clean(batch.frame)),
        candidate.execution_plan.batches)
    return (;native,publish,throw_first,parity,cleaned,
        state=PSE.final_state(candidate,:unit),report=Shared.shared_call_report(candidate))
end
function shared_nested_throw_checks()
    reports=Any[]
    @testset "Shared child call frame unwinds nested throw and immediate retry" begin
        for native in (false,true),publish in (false,true),throw_first in (false,true)
            result=shared_nested_throw_probe(;native,publish,throw_first)
            @test all(result.parity)
            @test result.cleaned
            @test result.state.root_visits==2
            @test result.report.executed_numerical_roots==2
            @test result.report.executed_numerical_calls>0
            @test result.report.fallback_calls==0
            @test result.report.constructed_rich_targets==0
            push!(reports,result)
        end
    end
    return (;passed=true,reports)
end

function shared_retained_checks()
    reports=Any[]
    @testset "Shared program retains One cache identity through unrelated birth" begin
        for native in (false,true),inspect_before_growth in (false,true),consume_refresh in (false,true)
            left,right=(capture=Any[],),(capture=Any[],)
            reference=PSE.run!(DirectChecks._retained_fixture(false);steps=0,outputs=:all,constants=left)
            candidate=Shared.prepare_shared_calls(DirectChecks._retained_fixture(native);
                steps=0,outputs=:all,constants=right,state_strategy=native ? :native : :references)
            PSE.step!(reference);PSE.step!(candidate)
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            saved_left,saved_right=only(left.capture),only(right.capture)
            if inspect_before_growth
                only(saved_left);only(saved_right)
            end
            for simulation in (reference,candidate)
                PSE.register_object!(simulation.model,PSE.Object(:spectator;status=(sentinel=1.0f0,)))
                if consume_refresh
                    PSE.refresh_bindings!(simulation.model)
                    PSE.refresh_environment_bindings!(simulation.model)
                end
            end
            PSE.step!(reference);PSE.step!(candidate)
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            @test saved_right===only(right.capture)
            @test only(saved_right).time==only(saved_left).time==2.0
            @test PSE.model_status(candidate.model,:unit).captured_time==2.0
            @test PSE.refvalue(only(saved_right).status,:value)===
                PSE.refvalue(PSE.model_status(candidate.model,:unit),:value)
            PSE.run_call!(only(saved_left);sampled_environment=5.0,publish=true)
            PSE.run_call!(only(saved_right);sampled_environment=5.0,publish=true)
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            report=Shared.shared_call_report(candidate)
            @test report.executed_numerical_roots==1
            @test report.executed_numerical_calls==1
            @test report.live_shared_batches==0
            push!(reports,(;native,inspect_before_growth,consume_refresh,report))
        end
    end
    return (;passed=true,reports)
end

PSE.@process "shared_conditional_root" verbose=false
PSE.@process "shared_conditional_middle" verbose=false
PSE.@process "shared_conditional_leaf" verbose=false
struct SharedConditionalRoot <: AbstractShared_Conditional_RootModel end
struct SharedConditionalMiddle <: AbstractShared_Conditional_MiddleModel end
struct SharedConditionalLeaf <: AbstractShared_Conditional_LeafModel end
PSE.inputs_(::SharedConditionalRoot)=(allow_publication=PSE.Required(Bool),)
PSE.outputs_(::SharedConditionalRoot)=(root_visits=0,)
PSE.inputs_(::SharedConditionalMiddle)=NamedTuple()
PSE.outputs_(::SharedConditionalMiddle)=(middle_visits=0,a_time=0.0,a_publication=true)
PSE.inputs_(::SharedConditionalLeaf)=NamedTuple()
PSE.outputs_(::SharedConditionalLeaf)=(leaf_visits=0,)
function PSE.run!(::SharedConditionalRoot,status,environment,constants,context)
    PSE.run_call!(context,:middle;sampled_environment=environment,publish=status.allow_publication)
    status.root_visits+=1
    return nothing
end
function PSE.run!(::SharedConditionalMiddle,status,environment,constants,context)
    if status.middle_visits>0 && hasproperty(constants,:query_skipped) && constants.query_skipped
        current=PSE.call_targets(context,:leaf)
        constants.lookup_identity[context.object_id.value]=current===constants.saved[context.object_id.value]
    end
    if status.middle_visits==0
        targets=PSE.run_call!(context,:leaf;sampled_environment=environment,publish=true)
        constants.saved[context.object_id.value]=targets
    elseif context.object_id.value===:b
        # Row A's leaf was not called this step. Materialize its saved result
        # while the shared middle frame is executing row B with another flag.
        # Without querying that binding, ordinary PSE keeps its previous time.
        target=only(constants.saved[:a])
        status.a_time=target.time
        status.a_publication=target.publication_allowed
    end
    status.middle_visits+=1
    return nothing
end
function PSE.run!(::SharedConditionalLeaf,status,environment,constants,context)
    status.leaf_visits+=1
    return nothing
end
for T in (SharedConditionalRoot,SharedConditionalMiddle,SharedConditionalLeaf)
    @eval Native.native_call_effects(::Type{$T})=:fixed_native_calls
    @eval Shared.shared_context_effects(::Type{$T})=:synchronous_borrowed_context
end
function _conditional_fixture(native)
    return PSE.CompositeModel((PSE.Object(id;kind=:conditional_unit,status=(
        allow_publication=id===:b,root_visits=0,middle_visits=0,leaf_visits=0,
        a_time=0.0,a_publication=true)) for id in (:a,:b))...;
        applications=(
            PSE.ModelSpec(SharedConditionalRoot();name=:root,on=PSE.Many(kind=:conditional_unit),
                every=Hour(1),calls=(middle=PSE.One(within=PSE.Self(),application=:middle),)),
            PSE.ModelSpec(SharedConditionalMiddle();name=:middle,on=PSE.Many(kind=:conditional_unit),
                every=Hour(1),calls=(leaf=PSE.One(within=PSE.Self(),application=:leaf),)),
            PSE.ModelSpec(SharedConditionalLeaf();name=:leaf,on=PSE.Many(kind=:conditional_unit),every=Hour(1)),
        ),environment=(duration=Hour(1),),status_storage=native ? PSE.NativeColumnStorage() : nothing)
end
function shared_conditional_checks()
    reports=Any[]
    @testset "Skipped child metadata and cross-row materialization stay independent" begin
        for native in (false,true)
            left,right=(saved=Dict{Symbol,Any}(),),(saved=Dict{Symbol,Any}(),)
            reference=PSE.run!(_conditional_fixture(false);steps=0,outputs=:all,constants=left)
            candidate=Shared.prepare_shared_calls(_conditional_fixture(native);steps=0,outputs=:all,
                constants=right,state_strategy=native ? :native : :references)
            for _ in 1:2
                PSE.step!(reference);PSE.step!(candidate)
                @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            end
            report=Shared.shared_call_report(candidate)
            @test report.executed_numerical_roots==4
            @test report.executed_numerical_calls==6
            @test report.fallback_calls==0
            @test report.shared_numerical_contexts==3
            @test report.program_cohorts==1
            reference_time=PSE.model_status(reference.model,:b).a_time
            @test PSE.model_status(candidate.model,:b).a_time==reference_time
            @test reference_time==1.0
            @test !PSE.model_status(candidate.model,:b).a_publication
            for id in (:a,:b)
                @test right.saved[id] isa PSE.CallTargets
                @test only(right.saved[id]).object_id==PSE.ObjectId(id)
                reference_time=only(left.saved[id]).time
                @test only(right.saved[id]).time==reference_time
                @test reference_time==1.0
                @test only(right.saved[id]).publication_allowed===only(left.saved[id]).publication_allowed===(id===:b)
                @test only(right.saved[id]).status===PSE.model_status(candidate.model,id)
            end
            push!(reports,(;native,report))
        end
    end
    return (;passed=true,reports)
end

function _root_conditional_fixture(native)
    return PSE.CompositeModel((PSE.Object(id;kind=:conditional_unit,status=(
        middle_visits=0,leaf_visits=0,a_time=0.0,a_publication=true)) for id in (:a,:b))...;
        applications=(
            PSE.ModelSpec(SharedConditionalMiddle();name=:middle,on=PSE.Many(kind=:conditional_unit),
                every=Hour(1),calls=(leaf=PSE.One(within=PSE.Self(),application=:leaf),)),
            PSE.ModelSpec(SharedConditionalLeaf();name=:leaf,on=PSE.Many(kind=:conditional_unit),every=Hour(1)),
        ),environment=(duration=Hour(1),),status_storage=native ? PSE.NativeColumnStorage() : nothing)
end

function shared_root_skipped_checks()
    reports=Any[]
    @testset "Scheduled root keeps unqueried metadata and synchronizes lookup-only collections" begin
        for native in (false,true),query_skipped in (false,true)
            constants()=(saved=Dict{Symbol,Any}(),lookup_identity=Dict{Symbol,Bool}(),query_skipped=query_skipped)
            left,right=constants(),constants()
            reference=PSE.run!(_root_conditional_fixture(false);steps=0,outputs=:all,constants=left)
            candidate=Shared.prepare_shared_calls(_root_conditional_fixture(native);steps=0,outputs=:all,
                constants=right,state_strategy=native ? :native : :references)
            for _ in 1:2
                PSE.step!(reference);PSE.step!(candidate)
                @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            end
            expected=query_skipped ? 2.0 : 1.0
            reference_time=PSE.model_status(reference.model,:b).a_time
            @test reference_time==expected
            @test PSE.model_status(candidate.model,:b).a_time==reference_time
            for id in (:a,:b)
                reference_target=only(left.saved[id])
                target=only(right.saved[id])
                @test target.time==reference_target.time
                @test reference_target.time==expected
                @test target.object_id==PSE.ObjectId(id)
                @test target.publication_allowed===reference_target.publication_allowed===true
                @test target.status===PSE.model_status(candidate.model,id)
            end
            if query_skipped
                @test all(values(left.lookup_identity))
                @test right.lookup_identity==left.lookup_identity
            else
                @test isempty(right.lookup_identity) && isempty(left.lookup_identity)
            end
            report=Shared.shared_call_report(candidate)
            @test report.executed_numerical_roots==4
            @test report.executed_numerical_calls==2
            push!(reports,(;native,query_skipped,report))
        end
    end
    return (;passed=true,reports)
end

function shared_fallback_checks()
    reports=Any[]
    @testset "Shared program retains unknown and unsupported kernel APIs" begin
        # Existing gate models have no audited borrowed-context capability, so
        # evaluation, overrides, selection and empty/nonempty Many stay ordinary.
        for builder in (() -> CR.gate_call_fixture(),() -> CR.gate_many_fixture(1),
            () -> CR.gate_many_fixture(0))
            reference=PSE.run!(builder();steps=0,outputs=:all)
            candidate=Shared.prepare_shared_calls(Native._native_gate_copy(builder());steps=0,outputs=:all)
            for _ in 1:2
                PSE.step!(reference);PSE.step!(candidate)
                @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            end
            report=Shared.shared_call_report(candidate)
            @test report.executed_numerical_roots==0
            @test report.executed_numerical_calls==0
            push!(reports,report)
        end
    end
    return (;passed=true,reports)
end

function shared_all_checks()
    return (pb=shared_pb_checks(),nested=shared_nested_throw_checks(),
        retained=shared_retained_checks(),conditional=shared_conditional_checks(),
        skipped_root=shared_root_skipped_checks(),
        fallback=shared_fallback_checks())
end

end
