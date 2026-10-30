module DirectManyChecks

using Dates, Test, PlantSimEngine
const PSE=PlantSimEngine
const Native=Main.NativePBDriver
const Direct=Main.DirectCallCompiler
const CR=Main.CompiledRegionsExperiment

export direct_many_probe, direct_many_checks

PSE.@process "direct_tracked_many_controller" verbose=false
PSE.@process "direct_tracked_many_worker" verbose=false
struct DirectTrackedManyController <: AbstractDirect_Tracked_Many_ControllerModel end
struct DirectTrackedManyWorker <: AbstractDirect_Tracked_Many_WorkerModel end
PSE.inputs_(::DirectTrackedManyController)=NamedTuple()
PSE.outputs_(::DirectTrackedManyController)=(visits=0,)
PSE.inputs_(::DirectTrackedManyWorker)=NamedTuple()
PSE.outputs_(::DirectTrackedManyWorker)=(value=0.0,)
function PSE.run!(::DirectTrackedManyController,status,environment,constants,context)
    targets=PSE.run_call!(context,:workers;publish=true)
    isempty(constants.capture) && push!(constants.capture,targets)
    status.visits+=1
    return nothing
end
function PSE.run!(::DirectTrackedManyWorker,status,environment,constants,context)
    status.value+=1.0
    return nothing
end
# These kernels have no unsupported effect: only the selector's lifecycle
# contract makes a singleton Many ineligible for a fixed singular call graph.
Native.native_call_effects(::Type{DirectTrackedManyController})=:fixed_native_calls
Native.native_call_effects(::Type{DirectTrackedManyWorker})=:fixed_native_calls

function _many_fixture(native)
    return PSE.CompositeModel(
        PSE.Object(:owner;status=(visits=0,)),
        PSE.Object(:worker_1;kind=:tracked_worker,status=(value=0.0,));
        applications=(
            PSE.ModelSpec(DirectTrackedManyController();name=:controller,
                on=PSE.One(id=:owner),every=Hour(1),calls=(
                    workers=PSE.Many(kind=:tracked_worker,within=PSE.SceneScope(),
                        application=:worker),)),
            PSE.ModelSpec(DirectTrackedManyWorker();name=:worker,
                on=PSE.Many(kind=:tracked_worker),every=Hour(1)),
        ),environment=(duration=Hour(1),),
        status_storage=native ? PSE.NativeColumnStorage() : nothing)
end

_membership(targets)=sort!([target.object_id.value for target in targets];by=string)

"""
Return bounded pre/post-refresh facts without assertions. This can demonstrate
the old singleton-Many hole before reloading the conservative lowering guard.
The first collection is retained across a second worker's registration and
externally consumed binding/environment refresh, exactly as user code may do.
"""
function direct_many_probe(;native=true,inspect_before_growth=true)
    left,right=(capture=Any[],),(capture=Any[],)
    reference=PSE.run!(_many_fixture(false);steps=0,outputs=:all,constants=left)
    candidate=Direct.prepare_direct_calls(_many_fixture(native);steps=0,outputs=:all,
        constants=right,state_strategy=native ? :native : :references)
    prepared_report=Direct.direct_call_report(candidate)
    guarded=any(reason->reason.reason===:tracked_many_call_boundary,
        prepared_report.reasons)
    PSE.step!(reference)
    PSE.step!(candidate)
    initial_same=isequal(CR.downstream_fingerprint(candidate),
        CR.downstream_fingerprint(reference))
    saved_reference,saved_candidate=only(left.capture),only(right.capture)
    are_collections=saved_reference isa PSE.CallTargets && saved_candidate isa PSE.CallTargets
    # Leaving the direct return uninspected also exercises a still-cold custom
    # deferred container in the pre-guard reproducer. The other arm explicitly
    # materializes that container before membership changes.
    initial_reference_membership=inspect_before_growth ? _membership(saved_reference) : nothing
    initial_candidate_membership=inspect_before_growth ? _membership(saved_candidate) : nothing
    for simulation in (reference,candidate)
        PSE.register_object!(simulation.model,
            PSE.Object(:worker_2;kind=:tracked_worker,status=(value=0.0,)))
        PSE.refresh_bindings!(simulation.model)
        PSE.refresh_environment_bindings!(simulation.model)
    end
    PSE.step!(reference)
    PSE.step!(candidate)
    reference_membership=_membership(saved_reference)
    candidate_membership=_membership(saved_candidate)
    same_state_and_history=isequal(CR.downstream_fingerprint(candidate),
        CR.downstream_fingerprint(reference))
    retained_identity=only(left.capture)===saved_reference && only(right.capture)===saved_candidate
    return (;native,inspect_before_growth,guarded,are_collections,retained_identity,initial_same,
        initial_reference_membership,initial_candidate_membership,
        reference_membership,candidate_membership,same_state_and_history,
        reference_newborn_value=PSE.model_status(reference.model,:worker_2).value,
        candidate_newborn_value=PSE.model_status(candidate.model,:worker_2).value,
        prepared_report,report=Direct.direct_call_report(candidate))
end

function direct_many_checks()
    reports=Any[]
    @testset "Singleton Many retains lifecycle-tracked collection membership" begin
        for native in (false,true), inspect_before_growth in (false,true)
            result=direct_many_probe(;native,inspect_before_growth)
            @test result.guarded
            @test result.are_collections
            @test result.retained_identity
            @test result.initial_same
            if inspect_before_growth
                @test result.initial_reference_membership==result.initial_candidate_membership==[:worker_1]
            end
            @test result.reference_membership==result.candidate_membership==[:worker_1,:worker_2]
            @test result.same_state_and_history
            @test result.reference_newborn_value==result.candidate_newborn_value==1.0
            @test result.prepared_report.direct_batches_prepared==0
            @test result.report.executed_numerical_roots==0
            @test result.report.executed_numerical_calls==0
            @test result.report.lazy_materializations==0
            push!(reports,result)
        end
    end
    return (;passed=true,reports)
end

end
