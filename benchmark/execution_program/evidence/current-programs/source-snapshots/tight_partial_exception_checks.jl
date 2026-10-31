module TightPartialExceptionChecks

using Dates,Test,PlantSimEngine
const PSE=PlantSimEngine
const Tight=Main.TightCallProgram
const Shared=Main.SharedCallProgram
const Native=Main.NativePBDriver
const Fixtures=Main.TightCallProgramChecks
const CR=Main.CompiledRegionsExperiment

export tight_partial_exception_checks

PSE.@process "tight_unhandled_leaf" verbose=false
struct TightUnhandledLeaf <: AbstractTight_Unhandled_LeafModel end
PSE.inputs_(::TightUnhandledLeaf)=(fail=PSE.Default(false),)
PSE.outputs_(::TightUnhandledLeaf)=(leaf_visits=0,value=0.0f0)
function PSE.run!(::TightUnhandledLeaf,status,environment,constants,context)
    status.leaf_visits+=1
    status.fail && throw(ArgumentError("tight unhandled leaf failure"))
    status.value+=0.5f0
    return nothing
end
Native.native_call_effects(::Type{TightUnhandledLeaf})=:fixed_native_calls
Native.direct_status_compatible(::Type{TightUnhandledLeaf})=true
Shared.shared_context_effects(::Type{TightUnhandledLeaf})=:synchronous_borrowed_context
Tight.tight_call_effects(::Type{TightUnhandledLeaf})=Tight._TIGHT_CAPABILITY

function _fixture(native)
    return PSE.CompositeModel((PSE.Object(id;kind=:partial_unit,status=(
        root_visits=0,caught=false,middle_visits=0,leaf_visits=0,value=0.0f0,fail=false)) for id in 1:3)...;
        applications=(
            PSE.ModelSpec(Fixtures.TightThrowRoot();name=:root,on=PSE.Many(kind=:partial_unit),every=Hour(1),
                calls=(middle=PSE.One(within=PSE.Self(),application=:middle),)),
            PSE.ModelSpec(Fixtures.TightThrowMiddle();name=:middle,on=PSE.Many(kind=:partial_unit),every=Hour(1),
                calls=(leaf=PSE.One(within=PSE.Self(),application=:leaf),)),
            PSE.ModelSpec(TightUnhandledLeaf();name=:leaf,on=PSE.Many(kind=:partial_unit),every=Hour(1)),
        ),environment=(duration=Hour(1),),status_storage=native ? PSE.NativeColumnStorage() : nothing)
end

function tight_partial_exception_checks()
    reports=Any[]
    @testset "Unhandled tight row failure preserves prior epochs of unentered rows" begin
        for native in (false,true),header_strategy in (:projected,:same_object_union)
            reference=PSE.run!(_fixture(false);steps=0,outputs=:all)
            candidate=Tight.prepare_tight_calls(_fixture(native);steps=0,outputs=:all,
                state_strategy=native ? :native : :references,header_strategy,count_calls=true)
            PSE.step!(reference);PSE.step!(candidate)
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            PSE.model_status(reference.model,2).fail=true
            PSE.model_status(candidate.model,2).fail=true
            left_error=try PSE.step!(reference);nothing catch error;error end
            right_error=try PSE.step!(candidate);nothing catch error;error end
            @test left_error isa ArgumentError
            @test typeof(right_error)===typeof(left_error)
            @test sprint(showerror,right_error)==sprint(showerror,left_error)
            @test PSE.current_step(candidate)==PSE.current_step(reference)==1
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            reference_owners=Dict(target.object_id=>target for batch in reference.execution_plan.batches
                for target in batch.targets)
            tight_batch=only(batch for batch in candidate.execution_plan.batches if batch isa Tight.TightBatch)
            owners=collect(tight_batch.targets)
            @test [owner.context.time for owner in owners]==[2.0,2.0,1.0]
            @test !tight_batch.active[]
            for owner in owners
                control=reference_owners[owner.object_id]
                @test owner.context.time==control.context.time
                @test !owner.call_context_cache.in_use
                @test owner.status===PSE.model_status(candidate.model,owner.object_id)
                # Once the first public lookup is made, its child collection
                # receives exactly this root's ordinary metadata epoch.
                expected=PSE.call_targets(control.context,:middle)
                actual=PSE.call_targets(owner.context,:middle)
                @test actual.time==expected.time==owner.context.time
                @test only(actual).time==only(expected).time
                @test !only(actual).context_cache.in_use
            end
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            report=Tight.tight_call_report(candidate)
            @test report.executed_numerical_roots==5
            @test report.executed_numerical_calls==10
            push!(reports,(;native,header_strategy,report))
        end
    end
    return (;passed=true,reports)
end

end
