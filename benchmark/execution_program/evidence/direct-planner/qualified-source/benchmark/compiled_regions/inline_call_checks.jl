# Generic gates for the isolated inlined-call strategy. No downstream model or
# object label influences compiler eligibility or execution.

PSE.@process "region_inline_nested_controller" verbose=false
struct InlineNestedController <: AbstractRegion_Inline_Nested_ControllerModel end
PSE.inputs_(::InlineNestedController) = NamedTuple()
PSE.outputs_(::InlineNestedController) = (nested_observed=0.0, nested_visits=0)
function PSE.run!(::InlineNestedController, status, environment, constants, context)
    row = GateSampledRow(1.0)
    PSE.run_call!(context, :middle; sampled_environment=row, publish=false)
    targets = PSE.run_call!(context, :middle; sampled_environment=row, publish=true)
    status.nested_observed = only(targets).status.published
    status.nested_visits = only(targets).status.visits
    return nothing
end
resolved_call_effects(::Type{InlineNestedController}) = :stable_calls

function inline_nested_fixture()
    return PSE.CompositeModel(PSE.Object(:root), PSE.Object(:owner),
        PSE.Object(:worker),
        PSE.Object(:column; status=PSE.Status(stage_1=0.0, visits_1=0));
        applications=(
            PSE.ModelSpec(InlineNestedController(); name=:root_controller,
                on=PSE.One(id=:root), every=Hour(1), calls=(
                    middle=PSE.One(id=:owner, within=PSE.SceneScope(),
                        application=:middle_controller),)),
            PSE.ModelSpec(GateCallController(); name=:middle_controller,
                on=PSE.One(id=:owner), every=Hour(1), calls=(
                    worker=PSE.One(id=:worker, within=PSE.SceneScope(),
                        application=:gate_worker),)),
            PSE.ModelSpec(GateCallWorker(); name=:gate_worker,
                on=PSE.One(id=:worker), every=Hour(1)),
            PSE.ModelSpec(GP.ChainStage{1,Float64,false}(0.5, 1.0);
                name=:column_stage, on=PSE.One(id=:column), every=Hour(1)),
        ), environment=(driver=1.0, duration=Hour(1)))
end

function run_inline_call_checks(; steps=3, regions_cases=(false, true))
    reports = NamedTuple[]
    cases = (
        (name=:trial_evaluate_publish, builder=gate_call_fixture, steps=steps),
        (name=:nested_calls_and_columns, builder=inline_nested_fixture, steps=steps),
        (name=:stale_evaluation, builder=() -> gate_call_fixture(GateStaleController()), steps=1),
        (name=:backend_override, builder=() -> gate_call_fixture(GateOverrideController()), steps=1),
        (name=:many_empty, builder=() -> gate_many_fixture(0), steps=2),
        (name=:many_one, builder=() -> gate_many_fixture(1), steps=2),
        (name=:many_three, builder=() -> gate_many_fixture(3), steps=2),
    )
    @testset "isolated inlined-call contracts and column composition" begin
        for case in cases, regions in regions_cases
            reference = PSE.run!(case.builder(); steps=case.steps, outputs=:all)
            simulation = PSE.run!(case.builder(); steps=0, outputs=:all)
            program = compile_regions(simulation; regions, resolved_calls=true,
                compact=regions, call_strategy=:inline)
            advance_regions!(program; steps=case.steps)
            @test isequal(downstream_fingerprint(simulation),
                downstream_fingerprint(reference))
            report = region_report(program)
            @test fast_call_count(report) > 0 || case.name === :backend_override
            @test !isempty(report.resolved_calls)
            @test all(row -> row.call_strategy === :inline &&
                row.inline_scientific_boundary, report.resolved_calls)
            if case.name === :trial_evaluate_publish
                state = PSE.final_state(simulation, :owner)
                @test state.trial == 2.0
                @test state.accepted == 3.0
                @test state.published == 4.0
                # evaluate_call! deliberately uses original target/context
                # views; accepted state and exact histories above are its
                # evidence, rather than an optimized-wrapper counter.
                @test PSE.final_state(simulation, :worker).value == 4.0
            elseif case.name === :nested_calls_and_columns
                state = PSE.final_state(simulation, :root)
                @test state.nested_observed == 4.0
                @test state.nested_visits == 2 * case.steps
                @test PSE.final_state(simulation, :worker).visits == 6 * case.steps
                middle = PSE.final_state(simulation, :owner)
                @test middle.trial == 2.0
                @test middle.accepted == 3.0
                @test middle.published == 4.0
                @test selected_region_count(report) == (regions ? 1 : 0)
                @test report.column_batch_executions == (regions ? case.steps : 0)
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

function run_inline_call_lifecycle_checks(; regions_cases=(false, true))
    reports = NamedTuple[]
    @testset "inlined calls after lifecycle and environment refresh" begin
        for regions in regions_cases
            reference_model = epoch_lifecycle_fixture()
            model = epoch_lifecycle_fixture()
            reference = PSE.run!(reference_model; steps=0, outputs=:all)
            simulation = PSE.run!(model; steps=0, outputs=:all)
            program = compile_regions(simulation; regions,
                resolved_calls=true, compact=regions, call_strategy=:inline)
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
            PSE.continue!(reference; steps=1)
            PSE.continue!(simulation; steps=1)
            @test isequal(downstream_fingerprint(simulation),
                downstream_fingerprint(reference))
            push!(reports, (; regions, report))
        end
    end
    return (; cases=length(reports), reports)
end
