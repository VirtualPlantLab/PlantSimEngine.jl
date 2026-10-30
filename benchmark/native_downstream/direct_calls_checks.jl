module DirectCallCompilerChecks
using Dates, Test, PlantSimEngine
const PSE=PlantSimEngine
const Native=Main.NativePBDriver
const Direct=Main.DirectCallCompiler
const CR=Main.CompiledRegionsExperiment

export direct_pb_checks, direct_metadata_checks, direct_escape_checks,
    direct_exception_checks, direct_retained_targets_checks, direct_buffer_checks, direct_all_checks

function direct_pb_checks(;nobjects=2,steps=2)
    reports=Any[]
    @testset "Direct logical call graph: original PB and canonical ownership" begin
        for native in (false,true), outputs in (:none,:all)
            reference=Native.pb_native_fixture(;native=false,nobjects,steps)
            fixture=Native.pb_native_fixture(;native,nobjects,steps)
            control=PSE.run!(reference.model;steps=0,outputs)
            candidate=Direct.prepare_direct_calls(fixture.model;steps=0,outputs,
                state_strategy=native ? :native : :references)
            before=Direct.direct_call_report(candidate)
            @test before.constructed_rich_targets==0
            @test before.skipped_rich_targets==3*nobjects
            @test before.lazy_materializations==0
            function shells_cold(node)
                node.original_context===nothing && all(entry->shells_cold(entry.node),
                    values(node.context.calls.entries))
            end
            @test all(batch->all(shells_cold,batch.rows),candidate.execution_plan.batches)
            canonical=PSE.model_status(fixture.model,1)
            escaped=PSE.refvalue(canonical,:Ra_SW_f)
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(control))
            for _ in 1:steps
                PSE.continue!(control;steps=1)
                PSE.step!(candidate)
                @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(control))
            end
            @test PSE.model_status(fixture.model,1)===canonical
            @test PSE.refvalue(canonical,:Ra_SW_f)===escaped
            report=Direct.direct_call_report(candidate)
            @test report.executed_numerical_roots==nobjects*steps
            @test report.executed_numerical_calls>0
            @test report.typed_model_lookups>0
            @test report.fallback_calls==0
            @test report.lazy_materializations==0
            @test report.constructed_rich_targets==0
            @test native ? report.executed_native_column_fields>0 : report.executed_native_column_fields==0
            @test report.shared_graph_shapes==3
            push!(reports,(;native,outputs,report))
        end
    end
    return (;passed=true,reports)
end

PSE.@process "direct_metadata_extra" verbose=false
struct DirectMetadataExtra <: AbstractDirect_Metadata_ExtraModel end
PSE.inputs_(::DirectMetadataExtra)=NamedTuple()
PSE.outputs_(::DirectMetadataExtra)=(foreign_signal=0.0f0,)
PSE.run!(::DirectMetadataExtra,status,environment,constants,context)=
    (status.foreign_signal+=1.0f0;nothing)

function _metadata_fixture(native)
    base=Native.pb_native_fixture(;native=false,nobjects=2,steps=3)
    metadata=[Dict(:geometry=>Int[id]) for id in 1:2]
    objects=[PSE.Object(object.id;kind=object.kind,scale=object.scale,
        status=merge(NamedTuple(object.status),(node=metadata[index],label=:arbitrary_metadata,)))
        for (index,object) in enumerate(PSE.model_objects(base.model))]
    applications=(base.model.applications...,
        PSE.ModelSpec(DirectMetadataExtra();name=:foreign_model,
            on=PSE.Many(kind=:gas_exchange_unit),every=Hour(1)))
    model=PSE.CompositeModel(objects...;applications,environment=base.model.environment,
        status_storage=native ? PSE.NativeColumnStorage() : nothing)
    return (;model,metadata)
end

function direct_metadata_checks()
    @testset "Direct numerical ports exclude unrelated mutable metadata" begin
        reference=_metadata_fixture(false)
        fixture=_metadata_fixture(true)
        control=PSE.run!(reference.model;steps=0,outputs=:all)
        candidate=Direct.prepare_direct_calls(fixture.model;steps=0,outputs=:all)
        @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(control))
        batches=[batch for batch in candidate.execution_plan.batches if batch isa Direct.DirectRootBatch]
        @test length(batches)==1
        for node in only(batches).rows
            @test :node ∉ keys(node.view.columns)
            @test :label ∉ keys(node.view.columns)
            @test :foreign_signal ∉ keys(node.view.columns)
            @test :node ∉ node.graph_shape.ports
            @test node.view.backing === PSE.model_status(fixture.model,node.object_id)
        end
        original=PSE.model_status(fixture.model,1)
        @test original.node === fixture.metadata[1]
        escaped=PSE.refvalue(original,:Ra_SW_f)
        for _ in 1:3
            PSE.continue!(control;steps=1)
            PSE.continue!(candidate;steps=1)
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(control))
        end
        @test original.node === fixture.metadata[1]
        @test escaped === PSE.refvalue(original,:Ra_SW_f)
        @test original.foreign_signal === 3.0f0
        report=Direct.direct_call_report(candidate)
        @test report.executed_numerical_roots==6
        @test report.executed_numerical_calls>0
        @test report.fallback_calls==0
        @test report.lazy_materializations==0
        reference_projection=Direct.prepare_direct_calls(_metadata_fixture(false).model;
            steps=0,outputs=:none,state_strategy=:references)
        projected_node=first(first(batch for batch in reference_projection.execution_plan.batches
            if batch isa Direct.DirectRootBatch).rows)
        @test Direct._direct_field_count(projected_node.view)==
            length(getfield(projected_node.view.status,:vars)) <
            length(keys(projected_node.view.status))
        return (;passed=true,report)
    end
end

function direct_escape_checks()
    function fixture(native)
        PSE.CompositeModel(PSE.Object(:escape;status=(value=0.0,visits=0));
            applications=(PSE.ModelSpec(Native.NativeReferenceEscape();name=:escape,
                on=PSE.One(id=:escape),every=Hour(1)),),environment=(duration=Hour(1),),
            status_storage=native ? PSE.NativeColumnStorage() : nothing)
    end
    left,right=(capture=Any[],),(capture=Any[],)
    control=PSE.run!(fixture(false);steps=0,outputs=:all,constants=left)
    candidate=Direct.prepare_direct_calls(fixture(true);steps=0,outputs=:all,constants=right)
    @testset "Direct kernels lend canonical escaped scientific references" begin
        PSE.continue!(control;steps=1);PSE.continue!(candidate;steps=1)
        @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(control))
        escaped=only(right.capture)
        canonical=PSE.refvalue(PSE.model_status(candidate.model,:escape),:value)
        @test escaped === canonical
        @test escaped isa Base.RefArray
        escaped[]=9.0;only(left.capture)[]=9.0
        PSE.continue!(control;steps=1);PSE.continue!(candidate;steps=1)
        @test escaped[]==10.0
        @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(control))
        @test Direct.direct_call_report(candidate).lazy_materializations==0
    end
    return (;passed=true,report=Direct.direct_call_report(candidate))
end

PSE.@process "direct_throw_root" verbose=false
PSE.@process "direct_throw_worker" verbose=false
struct DirectThrowRoot <: AbstractDirect_Throw_RootModel end
struct DirectThrowWorker <: AbstractDirect_Throw_WorkerModel end
PSE.inputs_(::DirectThrowRoot)=NamedTuple()
PSE.outputs_(::DirectThrowRoot)=(root_visits=0,after=0)
PSE.inputs_(::DirectThrowWorker)=(fail=PSE.Default(false),)
PSE.outputs_(::DirectThrowWorker)=(value=0.0,)
PSE.dep(::DirectThrowRoot)=(worker=PSE.Call(PSE.One(within=PSE.Self(),process=:direct_throw_worker)),)
function PSE.run!(::DirectThrowRoot,status,environment,constants,context)
    status.root_visits+=1
    PSE.run_call!(context,:worker;sampled_environment=1.0,publish=true)
    status.after+=1
    return nothing
end
function PSE.run!(::DirectThrowWorker,status,environment,constants,context)
    status.value+=environment
    status.fail && error("direct controlled failure")
    return nothing
end
Native.native_call_effects(::Type{DirectThrowRoot})=:fixed_native_calls
Native.native_call_effects(::Type{DirectThrowWorker})=:fixed_native_calls

function _exception_fixture(native)
    PSE.CompositeModel((PSE.Object(id;kind=:exception_unit,
        status=(fail=id==2,value=0.0,root_visits=0,after=0)) for id in 1:2)...;
        applications=(PSE.ModelSpec(DirectThrowRoot();name=:root,
            on=PSE.Many(kind=:exception_unit),every=Hour(1)),
            PSE.ModelSpec(DirectThrowWorker();name=:worker,
                on=PSE.Many(kind=:exception_unit),every=Hour(1))),
        environment=(duration=Hour(1),),status_storage=native ? PSE.NativeColumnStorage() : nothing)
end
function direct_exception_checks()
    control=PSE.run!(_exception_fixture(false);steps=0,outputs=:all)
    candidate=Direct.prepare_direct_calls(_exception_fixture(true);steps=0,outputs=:all)
    @testset "Direct per-row partial publication and exception cleanup" begin
        @test_throws ErrorException PSE.continue!(control;steps=1)
        @test_throws ErrorException PSE.continue!(candidate;steps=1)
        @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(control))
        @test PSE.current_step(candidate)==0
        @test PSE.final_state(candidate,1).after==1
        @test PSE.final_state(candidate,2).after==0
        for batch in candidate.execution_plan.batches
            batch isa Direct.DirectRootBatch || continue
            for row in batch.rows
                @test !row.in_use && !row.lease.running
                @test all(entry->!entry.node.in_use,values(row.context.calls.entries))
            end
        end
        # A failed step consumes the ordinary scheduler entry. Preserve the
        # same retry rejection instead of inventing rollback/retry semantics.
        left_error=try PSE.continue!(control;steps=1);nothing catch error;error end
        right_error=try PSE.continue!(candidate;steps=1);nothing catch error;error end
        @test left_error isa Exception
        @test typeof(right_error)===typeof(left_error)
        @test sprint(showerror,right_error)==sprint(showerror,left_error)
        @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(control))
        @test Direct.direct_call_report(candidate).lazy_materializations==0
        PSE.model_status(control.model,2).fail=false
        PSE.model_status(candidate.model,2).fail=false
        fresh_control=PSE.run!(control.model;steps=0,outputs=:all)
        fresh_candidate=Direct.prepare_direct_calls(candidate.model;steps=0,outputs=:all)
        PSE.continue!(fresh_control;steps=1)
        PSE.continue!(fresh_candidate;steps=1)
        @test isequal(CR.downstream_fingerprint(fresh_candidate),CR.downstream_fingerprint(fresh_control))
    end
    return (;passed=true,report=Direct.direct_call_report(candidate))
end

PSE.@process "direct_retained_controller" verbose=false
PSE.@process "direct_retained_worker" verbose=false
struct DirectRetainedController <: AbstractDirect_Retained_ControllerModel end
struct DirectRetainedWorker <: AbstractDirect_Retained_WorkerModel end
PSE.inputs_(::DirectRetainedController)=NamedTuple()
PSE.outputs_(::DirectRetainedController)=(phase=0,observed=0.0,captured_time=0.0)
PSE.inputs_(::DirectRetainedWorker)=NamedTuple()
PSE.outputs_(::DirectRetainedWorker)=(value=0.0,)
PSE.dep(::DirectRetainedController)=(worker=PSE.Call(PSE.One(within=PSE.Self(),process=:direct_retained_worker)),)
function PSE.run!(::DirectRetainedWorker,status,environment,constants,context)
    status.value+=environment
    if hasproperty(constants,:buffer_probe) && constants.buffer_probe[] &&
       !isempty(constants.capture)
        constants.buffer_probe[]=false
        PSE.with_call_targets(only(constants.capture)) do views
            constants.buffer_observed[]=only(views).status.value
        end
    end
    return nothing
end
function PSE.run!(::DirectRetainedController,status,environment,constants,context)
    targets=PSE.run_call!(context,:worker;sampled_environment=2.0,publish=false)
    if status.phase==0
        push!(constants.capture,targets)
    else
        retained=only(constants.capture)
        target=only(retained)
        status.captured_time=target.time
        # A result retained from the earlier fast call remains the same cached
        # wrapper, with live canonical state and current caller metadata.
        reference=PSE.refvalue(target.status,:value)
        reference[]=reference[]+3.0
        PSE.run_call!(target;sampled_environment=4.0,publish=true)
        status.observed=target.status.value
    end
    status.phase+=1
    return nothing
end
Native.native_call_effects(::Type{DirectRetainedController})=:fixed_native_calls
Native.native_call_effects(::Type{DirectRetainedWorker})=:fixed_native_calls
function _retained_fixture(native)
    PSE.CompositeModel(PSE.Object(:unit;status=(value=0.0,phase=0,observed=0.0,captured_time=0.0));
        applications=(PSE.ModelSpec(DirectRetainedController();name=:controller,
            on=PSE.One(id=:unit),every=Hour(1)),
            PSE.ModelSpec(DirectRetainedWorker();name=:worker,
                on=PSE.One(id=:unit),every=Hour(1))),
        environment=(duration=Hour(1),),status_storage=native ? PSE.NativeColumnStorage() : nothing)
end
function direct_retained_targets_checks()
    left,right=(capture=Any[],),(capture=Any[],)
    control=PSE.run!(_retained_fixture(false);steps=0,outputs=:all,constants=left)
    candidate=Direct.prepare_direct_calls(_retained_fixture(true);steps=0,outputs=:all,constants=right)
    @testset "Direct fast return materializes one persistent ordinary cache tree" begin
        for step in 1:3
            PSE.continue!(control;steps=1);PSE.continue!(candidate;steps=1)
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(control))
            step==1 && (@test Direct.direct_call_report(candidate).lazy_materializations==0)
        end
        report=Direct.direct_call_report(candidate)
        @test report.executed_numerical_roots==2
        @test report.executed_numerical_calls==2
        @test report.lazy_materializations==1
        @test report.ordinary_root_executions==1
        @test report.constructed_rich_targets==2
        @test only(right.capture) isa PSE.CallTargets
        target=only(only(right.capture))
        @test PSE.refvalue(target.status,:value) ===
            PSE.refvalue(PSE.model_status(candidate.model,:unit),:value)
        @test target.time==3.0
        @test !target.context_cache.in_use
    end
    return (;passed=true,report=Direct.direct_call_report(candidate))
end

function direct_buffer_checks()
    constants()=(capture=Any[],buffer_probe=Ref(true),buffer_observed=Ref(0.0),
        after_observed=Ref(0.0))
    left,right=constants(),constants()
    control=PSE.run!(_retained_fixture(false);steps=0,outputs=:all,constants=left)
    candidate=Direct.prepare_direct_calls(_retained_fixture(true);steps=0,outputs=:all,constants=right)
    @testset "Direct public buffers survive reentrant and released owner modes" begin
        PSE.continue!(control;steps=1);PSE.continue!(candidate;steps=1)
        @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(control))
        for data in (left,right)
            targets=only(data.capture)
            PSE.with_call_targets(targets) do views
                PSE.run_call!(only(views);sampled_environment=3.0,publish=true)
                # The worker inspected the same collection while its owner
                # cache was in use. A second view now has released-cache mode.
                PSE.with_call_targets(targets) do after
                    data.after_observed[]=only(after).status.value
                end
            end
            @test !targets.target_buffer_cache.first.in_use
            @test !targets.target_buffer_cache.second.in_use
        end
        @test left.buffer_observed[]==right.buffer_observed[]==5.0
        @test left.after_observed[]==right.after_observed[]==5.0
        @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(control))
        PSE.continue!(control;steps=1);PSE.continue!(candidate;steps=1)
        @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(control))
    end
    return (;passed=true,report=Direct.direct_call_report(candidate))
end

function direct_all_checks()
    return (pb=direct_pb_checks(),metadata=direct_metadata_checks(),
        escape=direct_escape_checks(),exceptions=direct_exception_checks(),
        retained_targets=direct_retained_targets_checks(),buffers=direct_buffer_checks())
end
end
