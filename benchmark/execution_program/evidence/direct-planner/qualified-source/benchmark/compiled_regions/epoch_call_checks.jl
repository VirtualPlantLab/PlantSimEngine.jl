# Included after checks.jl. Small gates only; root executes through Kaimon.

function run_epoch_call_checks(; steps=3)
    reports = NamedTuple[]
    cases = (
        (name=:trial_evaluate_publish, builder=gate_call_fixture, steps=steps),
        (name=:stale_evaluation, builder=() -> gate_call_fixture(GateStaleController()), steps=1),
        (name=:backend_override, builder=() -> gate_call_fixture(GateOverrideController()), steps=1),
        (name=:many_empty, builder=() -> gate_many_fixture(0), steps=2),
        (name=:many_one, builder=() -> gate_many_fixture(1), steps=2),
        (name=:many_three, builder=() -> gate_many_fixture(3), steps=2),
    )
    @testset "synchronous resolved-call epochs" begin
        for case in cases, regions in (false, true)
            reference = PSE.run!(case.builder(); steps=case.steps, outputs=:all)
            simulation = PSE.run!(case.builder(); steps=0, outputs=:all)
            program = compile_regions(simulation; regions, resolved_calls=true,
                compact=regions, call_strategy=:epoch)
            advance_regions!(program; steps=case.steps)
            @test isequal(downstream_fingerprint(simulation),
                downstream_fingerprint(reference))
            report = region_report(program)
            @test fast_call_count(report) > 0 || case.name === :backend_override
            @test !isempty(report.resolved_calls)
            @test all(row -> row.call_strategy === :epoch, report.resolved_calls)
            @test all(row -> !row.epoch_active_after_invocation, report.resolved_calls)
            @test all(row -> row.epoch_task_fallbacks == 0, report.resolved_calls)
            if case.name === :trial_evaluate_publish
                @test PSE.final_state(simulation, :owner).trial == 2.0
                @test PSE.final_state(simulation, :owner).accepted == 3.0
                @test PSE.final_state(simulation, :owner).published == 4.0
                @test call_report_metric(report, :epoch_invalidations) > 0
                @test call_report_metric(report, :epoch_revalidations) > 0
            elseif case.name === :stale_evaluation
                @test PSE.final_state(simulation, :owner).stale_rejected
            elseif case.name === :backend_override
                @test call_report_metric(report, :environment_fallbacks) > 0
            else
                expected_count = case.name === :many_empty ? 0 :
                    case.name === :many_one ? 1 : 3
                state = PSE.final_state(simulation, :owner)
                @test state.target_count == expected_count
                @test state.absent_count == 0
            end
            push!(reports, (; case=case.name, regions, report))
        end
    end
    return (; cases=length(reports), reports)
end

# A separate ordered grower changes membership between two controller calls.
# External addition then forces a cold rebuild before any ordinary call has had
# a chance to lazily synchronize an old manual target's context.
PSE.@process "region_call_epoch_lifecycle_controller" verbose=false
PSE.@process "region_call_epoch_lifecycle_grower" verbose=false
struct EpochLifecycleController <: AbstractRegion_Call_Epoch_Lifecycle_ControllerModel end
struct EpochLifecycleGrower <: AbstractRegion_Call_Epoch_Lifecycle_GrowerModel end
PSE.inputs_(::EpochLifecycleController) = NamedTuple()
PSE.outputs_(::EpochLifecycleController) = (target_count=0, total=0.0, visits=0)
function PSE.run!(::EpochLifecycleController, status, environment, constants, context)
    targets = PSE.run_call!(context, :workers;
        sampled_environment=GateSampledRow(context.time), publish=true)
    status.target_count = length(targets)
    status.total = sum(target.status.value for target in targets; init=0.0)
    status.visits += 1
    return nothing
end
resolved_call_effects(::Type{EpochLifecycleController}) = :stable_calls
PSE.inputs_(::EpochLifecycleGrower) = NamedTuple()
PSE.outputs_(::EpochLifecycleGrower) = (created=false,)
function PSE.run!(::EpochLifecycleGrower, status, environment, constants, context)
    if context.time == 2 && !status.created
        PSE.register_object!(PSE.runtime_model(context),
            PSE.Object(:worker_internal; kind=:epoch_lifecycle_worker,
                status=PSE.Status(value=0.0, visits=0)))
        status.created = true
    end
    return nothing
end

function epoch_lifecycle_fixture()
    return PSE.CompositeModel(
        PSE.Object(:grower), PSE.Object(:controller),
        PSE.Object(:worker_initial; kind=:epoch_lifecycle_worker);
        applications=(
            PSE.ModelSpec(EpochLifecycleGrower(); name=:a_grower,
                on=PSE.One(id=:grower), every=Hour(1)),
            PSE.ModelSpec(EpochLifecycleController(); name=:controller,
                on=PSE.One(id=:controller), every=Hour(1), calls=(
                    workers=PSE.Many(kind=:epoch_lifecycle_worker,
                        within=PSE.SceneScope(), application=:worker),)),
            PSE.ModelSpec(GateCallWorker(); name=:worker,
                on=PSE.Many(kind=:epoch_lifecycle_worker), every=Hour(1)),
        ), environment=(driver=1.0, duration=Hour(1)))
end

function run_call_lifecycle_checks()
    reports = NamedTuple[]
    @testset "resolved calls after lifecycle and environment refresh" begin
        for strategy in (:guarded, :epoch)
            reference_model = epoch_lifecycle_fixture()
            model = epoch_lifecycle_fixture()
            reference = PSE.run!(reference_model; steps=0, outputs=:all)
            simulation = PSE.run!(model; steps=0, outputs=:all)
            program = compile_regions(simulation; regions=false,
                resolved_calls=true, compact=false, call_strategy=strategy)
            for step in 1:3
                PSE.continue!(reference; steps=1)
                advance_regions!(program; steps=1)
                @test isequal(downstream_fingerprint(simulation),
                    downstream_fingerprint(reference))
                @test PSE.final_state(simulation, :controller).target_count == (step == 1 ? 1 : 2)
            end
            for scene in (reference_model, model)
                PSE.register_object!(scene,
                    PSE.Object(:worker_external; kind=:epoch_lifecycle_worker,
                        status=PSE.Status(value=0.0, visits=0)))
                PSE.mark_environment_binding_dirty!(scene, :worker_initial)
            end
            PSE.continue!(reference; steps=1)
            advance_regions!(program; steps=1)
            @test isequal(downstream_fingerprint(simulation),
                downstream_fingerprint(reference))
            @test PSE.final_state(simulation, :controller).target_count == 3
            @test PSE.final_state(simulation, :controller).total == 12.0
            report = region_report(program)
            @test report.rebuilds > 0
            @test fast_call_count(report) > 0
            # Public continuation must work after the replacement contexts.
            PSE.continue!(reference; steps=1)
            PSE.continue!(simulation; steps=1)
            @test isequal(downstream_fingerprint(simulation),
                downstream_fingerprint(reference))
            push!(reports, (; strategy, report))
        end
    end
    return (; cases=length(reports), reports)
end
