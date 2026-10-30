module TightCallProgramChecks

using Dates,Test,PlantSimEngine
const PSE=PlantSimEngine
const Tight=Main.TightCallProgram
const Shared=Main.SharedCallProgram
const Native=Main.NativePBDriver
const CR=Main.CompiledRegionsExperiment
const DirectChecks=Main.DirectCallCompilerChecks

export tight_pb_checks,tight_exception_checks,tight_union_boundary_checks,
    tight_public_fallback_checks,tight_retirement_checks,tight_environment_checks,tight_all_checks

function tight_pb_checks(;nobjects=2,steps=2,
    header_strategies=(:projected,:same_object_union),counter_modes=(false,true))
    reports=Any[]
    @testset "Private unpublished typed calls and independent union header" begin
        for native in (false,true),header_strategy in header_strategies,
            count_calls in counter_modes,outputs in (:none,:all)
            reference=PSE.run!(Native.pb_native_fixture(;native=false,nobjects,steps).model;steps=0,outputs)
            fixture=Native.pb_native_fixture(;native,nobjects,steps)
            candidate=Tight.prepare_tight_calls(fixture.model;steps=0,outputs,
                state_strategy=native ? :native : :references,header_strategy,count_calls)
            prepared=Tight.tight_call_report(candidate)
            @test prepared.tight_batches_prepared==1
            @test prepared.lazy_public_wrappers==0
            @test prepared.constructed_rich_targets==0
            canonical=PSE.model_status(fixture.model,1)
            escaped=PSE.refvalue(canonical,:Ra_SW_f)
            for _ in 1:steps
                PSE.step!(reference);PSE.step!(candidate)
                @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            end
            @test PSE.model_status(fixture.model,1)===canonical
            @test PSE.refvalue(canonical,:Ra_SW_f)===escaped
            report=Tight.tight_call_report(candidate)
            @test report.tight_batch_executions==steps
            @test report.fallback_batch_executions==0
            @test report.full_shared_numerical_roots==0
            @test report.lazy_public_wrappers==0
            @test report.constructed_rich_targets==0
            if count_calls
                @test report.executed_numerical_roots==nobjects*steps
                @test report.executed_numerical_calls>0
                @test report.typed_model_lookups>0
                @test (report.executed_native_column_fields>0)===native
            else
                @test ismissing(report.executed_numerical_roots)
                @test ismissing(report.executed_numerical_calls)
                @test report.counters===:compiled_out
            end
            push!(reports,(;native,header_strategy,count_calls,outputs,report))
        end
    end
    return (;passed=true,reports)
end

PSE.@process "tight_throw_root" verbose=false
PSE.@process "tight_throw_middle" verbose=false
PSE.@process "tight_throw_leaf" verbose=false
struct TightThrowRoot <: AbstractTight_Throw_RootModel end
struct TightThrowMiddle <: AbstractTight_Throw_MiddleModel end
struct TightThrowLeaf <: AbstractTight_Throw_LeafModel
    throw_first::Bool
end
PSE.inputs_(::TightThrowRoot)=NamedTuple()
PSE.inputs_(::TightThrowMiddle)=NamedTuple()
PSE.inputs_(::TightThrowLeaf)=NamedTuple()
PSE.outputs_(::TightThrowRoot)=(root_visits=0,caught=false)
PSE.outputs_(::TightThrowMiddle)=(middle_visits=0,)
PSE.outputs_(::TightThrowLeaf)=(leaf_visits=0,value=0.0f0)
function PSE.run!(::TightThrowRoot,status,environment,constants,context)
    try
        PSE.run_call!(context,:middle;sampled_environment=environment,publish=false)
    catch error
        error isa ErrorException && error.msg=="tight controlled failure" || rethrow()
        status.caught=true
        PSE.run_call!(context,:middle;sampled_environment=environment,publish=false)
    end
    status.root_visits+=1
    return nothing
end
function PSE.run!(::TightThrowMiddle,status,environment,constants,context)
    status.middle_visits+=1
    PSE.run_call!(context,:leaf;sampled_environment=environment,publish=false)
    return nothing
end
function PSE.run!(model::TightThrowLeaf,status,environment,constants,context)
    status.leaf_visits+=1
    model.throw_first && status.leaf_visits==1 && error("tight controlled failure")
    status.value+=0.5f0
    return nothing
end
for T in (TightThrowRoot,TightThrowMiddle,TightThrowLeaf)
    @eval Native.native_call_effects(::Type{$T})=:fixed_native_calls
    @eval Native.direct_status_compatible(::Type{$T})=true
    @eval Shared.shared_context_effects(::Type{$T})=:synchronous_borrowed_context
    @eval Tight.tight_call_effects(::Type{$T})=Tight._TIGHT_CAPABILITY
end
function _throw_fixture(native;throw_first=true,same_object=true,many=false)
    objects=same_object ? (PSE.Object(:unit;status=(root_visits=0,caught=false,middle_visits=0,
        leaf_visits=0,value=0.0f0)),) : (
        PSE.Object(:unit;status=(root_visits=0,caught=false)),
        PSE.Object(:middle;status=(middle_visits=0,)),
        PSE.Object(:leaf;status=(leaf_visits=0,value=0.0f0)))
    middle_id=same_object ? :unit : :middle
    leaf_id=same_object ? :unit : :leaf
    selector=many ? PSE.Many(id=middle_id,within=PSE.SceneScope(),application=:middle) :
        PSE.One(id=middle_id,within=PSE.SceneScope(),application=:middle)
    return PSE.CompositeModel(objects...;applications=(
        PSE.ModelSpec(TightThrowRoot();name=:root,on=PSE.One(id=:unit),every=Hour(1),calls=(middle=selector,)),
        PSE.ModelSpec(TightThrowMiddle();name=:middle,on=PSE.One(id=middle_id),every=Hour(1),calls=(
            leaf=PSE.One(id=leaf_id,within=PSE.SceneScope(),application=:leaf),)),
        PSE.ModelSpec(TightThrowLeaf(throw_first);name=:leaf,on=PSE.One(id=leaf_id),every=Hour(1)),
    ),environment=(duration=Hour(1),),status_storage=native ? PSE.NativeColumnStorage() : nothing)
end
function tight_exception_checks()
    reports=Any[]
    @testset "Tight noinline child boundaries preserve nested throw and retry" begin
        for native in (false,true),header_strategy in (:projected,:same_object_union),throw_first in (false,true)
            reference=PSE.run!(_throw_fixture(false;throw_first);steps=0,outputs=:all)
            candidate=Tight.prepare_tight_calls(_throw_fixture(native;throw_first);steps=0,outputs=:all,
                state_strategy=native ? :native : :references,header_strategy,count_calls=true)
            for _ in 1:2
                PSE.step!(reference);PSE.step!(candidate)
                @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            end
            report=Tight.tight_call_report(candidate)
            @test report.executed_numerical_roots==2
            @test report.executed_numerical_calls==(throw_first ? 6 : 4)
            @test report.lazy_public_wrappers==0
            @test report.constructed_rich_targets==0
            push!(reports,(;native,header_strategy,throw_first,report))
        end
    end
    return (;passed=true,reports)
end
function tight_union_boundary_checks()
    reports=Any[]
    @testset "Union header requires one proven canonical object" begin
        for header_strategy in (:projected,:same_object_union)
            reference=PSE.run!(_throw_fixture(false;same_object=false);steps=0,outputs=:all)
            candidate=Tight.prepare_tight_calls(_throw_fixture(true;same_object=false);
                steps=0,outputs=:all,header_strategy,count_calls=true)
            prepared=Tight.tight_call_report(candidate)
            @test prepared.tight_batches_prepared==(header_strategy===:projected ? 1 : 0)
            for _ in 1:2
                PSE.step!(reference);PSE.step!(candidate)
                @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            end
            report=Tight.tight_call_report(candidate)
            if header_strategy===:same_object_union
                @test report.executed_numerical_roots==0
                @test report.full_shared_numerical_roots==2
                @test any(reason->reason.reason===:union_header_requires_identical_canonical_status,report.reasons)
            else
                @test report.executed_numerical_roots==2
            end
            push!(reports,(;header_strategy,report))
        end
    end
    return (;passed=true,reports)
end

function tight_public_fallback_checks()
    reports=Any[]
    @testset "Retained results and all public/evaluation calls retain their full protocol" begin
        left,right=(capture=Any[],),(capture=Any[],)
        reference=PSE.run!(DirectChecks._retained_fixture(false);steps=0,outputs=:all,constants=left)
        candidate=Tight.prepare_tight_calls(DirectChecks._retained_fixture(true);
            steps=0,outputs=:all,constants=right,count_calls=true)
        @test Tight.tight_call_report(candidate).tight_batches_prepared==0
        for _ in 1:3
            PSE.step!(reference);PSE.step!(candidate)
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
        end
        @test only(right.capture) isa PSE.CallTargets
        @test only(only(right.capture)).time==only(only(left.capture)).time
        report=Tight.tight_call_report(candidate)
        @test report.executed_numerical_roots==0
        @test report.full_shared_numerical_roots>0
        push!(reports,(case=:retained_one,report))
        for builder in (() -> CR.gate_call_fixture(),() -> CR.gate_call_fixture(CR.GateOverrideController()),
            () -> _throw_fixture(false;many=true))
            reference=PSE.run!(builder();steps=0,outputs=:all)
            candidate=Tight.prepare_tight_calls(Native._native_gate_copy(builder());steps=0,outputs=:all,count_calls=true)
            @test Tight.tight_call_report(candidate).tight_batches_prepared==0
            for _ in 1:2
                PSE.step!(reference);PSE.step!(candidate)
                @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            end
            report=Tight.tight_call_report(candidate)
            @test report.executed_numerical_roots==0
            push!(reports,(case=:public_or_many_fallback,report))
        end
    end
    return (;passed=true,reports)
end

function tight_retirement_checks()
    reports=Any[]
    @testset "Tight external materialization and lifecycle regain current ordinary metadata" begin
        for inspect in (false,true),consume_refresh in (false,true)
            reference=PSE.run!(_throw_fixture(false;throw_first=false);steps=0,outputs=:all)
            candidate=Tight.prepare_tight_calls(_throw_fixture(true;throw_first=false);
                steps=0,outputs=:all,count_calls=true)
            PSE.step!(reference);PSE.step!(candidate)
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            if inspect
                batch=only(batch for batch in candidate.execution_plan.batches if batch isa Tight.TightBatch)
                owner=only(batch.targets)
                @test owner.context.time==1.0
                @test owner.status===PSE.model_status(candidate.model,:unit)
            end
            for simulation in (reference,candidate)
                PSE.register_object!(simulation.model,PSE.Object(:spectator;status=(sentinel=1.0f0,)))
                if consume_refresh
                    PSE.refresh_bindings!(simulation.model)
                    PSE.refresh_environment_bindings!(simulation.model)
                end
            end
            for _ in 1:2
                PSE.step!(reference);PSE.step!(candidate)
                @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            end
            report=Tight.tight_call_report(candidate)
            @test report.executed_numerical_roots==1
            @test report.live_tight_batches==0
            push!(reports,(;inspect,consume_refresh,report))
        end
    end
    return (;passed=true,reports)
end

PSE.@process "tight_environment_root" verbose=false
PSE.@process "tight_environment_worker" verbose=false
struct TightEnvironmentRoot <: AbstractTight_Environment_RootModel end
struct TightEnvironmentWorker <: AbstractTight_Environment_WorkerModel end
PSE.inputs_(::TightEnvironmentRoot)=NamedTuple()
PSE.inputs_(::TightEnvironmentWorker)=NamedTuple()
PSE.outputs_(::TightEnvironmentRoot)=(root_visits=0,)
PSE.outputs_(::TightEnvironmentWorker)=(value=0.0,visits=0)
PSE.environment_inputs_(::TightEnvironmentWorker)=(driver=Float64[0.0],)
function PSE.run!(::TightEnvironmentRoot,status,environment,constants,context)
    # Missing sampled_environment deliberately exercises each child's compiled
    # sampling handle instead of assuming it receives the parent's row.
    PSE.run_call!(context,:worker;publish=false)
    status.root_visits+=1
    return nothing
end
function PSE.run!(::TightEnvironmentWorker,status,environment,constants,context)
    status.value=only(environment.driver)
    status.visits+=1
    return nothing
end
for T in (TightEnvironmentRoot,TightEnvironmentWorker)
    @eval Native.native_call_effects(::Type{$T})=:fixed_native_calls
    @eval Native.direct_status_compatible(::Type{$T})=true
    @eval Shared.shared_context_effects(::Type{$T})=:synchronous_borrowed_context
    @eval Tight.tight_call_effects(::Type{$T})=Tight._TIGHT_CAPABILITY
end
function _environment_fixture(native)
    driver=Float64[1.0]
    model=PSE.CompositeModel(PSE.Object(:unit;status=(root_visits=0,value=0.0,visits=0));applications=(
        PSE.ModelSpec(TightEnvironmentRoot();name=:root,on=PSE.One(id=:unit),every=Hour(1),calls=(
            worker=PSE.One(within=PSE.Self(),application=:worker),)),
        PSE.ModelSpec(TightEnvironmentWorker();name=:worker,on=PSE.One(id=:unit),every=Hour(1)),
    ),environment=(driver=driver,duration=Hour(1),),status_storage=native ? PSE.NativeColumnStorage() : nothing)
    return (;model,driver)
end
function tight_environment_checks()
    @testset "Tight missing sampled row uses fresh mutable committed environment values" begin
        left,right=_environment_fixture(false),_environment_fixture(true)
        reference=PSE.run!(left.model;steps=0,outputs=:all)
        candidate=Tight.prepare_tight_calls(right.model;steps=0,outputs=:all,count_calls=true)
        for value in (1.0,7.0)
            left.driver[1]=right.driver[1]=value
            PSE.step!(reference);PSE.step!(candidate)
            @test PSE.model_status(candidate.model,:unit).value==value
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
        end
        report=Tight.tight_call_report(candidate)
        @test report.executed_numerical_roots==2
        @test report.executed_numerical_calls==2
        return (;passed=true,report)
    end
end

function tight_all_checks()
    return (pb=tight_pb_checks(),exceptions=tight_exception_checks(),
        union_boundary=tight_union_boundary_checks(),public_fallback=tight_public_fallback_checks(),
        retirement=tight_retirement_checks(),environment=tight_environment_checks())
end

end
