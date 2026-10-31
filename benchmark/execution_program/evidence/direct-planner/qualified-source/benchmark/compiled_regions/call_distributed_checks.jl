# A scheduled generic distributed writer runs alongside an actually selected
# regular inline call and, in the combined arm, an independent column region.
# Distributed manual-only callees are rejected by the original compiler and
# are not part of this supported composition.
PSE.@process "region_call_distributed_controller" verbose=false
struct CallDistributedController <: AbstractRegion_Call_Distributed_ControllerModel end
PSE.inputs_(::CallDistributedController) = NamedTuple()
PSE.outputs_(::CallDistributedController) = (inline_observed=0.0,)
function PSE.run!(::CallDistributedController, status, environment, constants, context)
    targets = PSE.run_call!(context, :worker;
        sampled_environment=GateSampledRow(7.0), publish=true)
    status.inline_observed = only(targets).status.value
    return nothing
end
resolved_call_effects(::Type{CallDistributedController}) = :stable_calls
# The existing generic fixture changes declared local/distributed statuses only;
# its deliberately invalid first assignment is caught inside the kernel.
resolved_call_effects(::Type{GP.CompletionValidatedAssignment}) = :stable_calls

function call_distributed_fixture()
    return PSE.CompositeModel(PSE.Object(:controller), PSE.Object(:call_worker),
        PSE.Object(:owner),
        PSE.Object(:unit_a; kind=:destination),
        PSE.Object(:unit_b; kind=:destination),
        PSE.Object(:column; status=PSE.Status(stage_1=0.0, visits_1=0));
        applications=(
            PSE.ModelSpec(CallDistributedController(); name=:controller,
                on=PSE.One(id=:controller), every=Hour(1), calls=(
                    worker=PSE.One(id=:call_worker, within=PSE.SceneScope(),
                        application=:gate_worker),)),
            PSE.ModelSpec(GateCallWorker(); name=:gate_worker,
                on=PSE.One(id=:call_worker), every=Hour(1)),
            PSE.ModelSpec(GP.CompletionValidatedAssignment(); name=:writer,
                on=PSE.One(id=:owner), every=Hour(1), outputs_to=(
                    PSE.OutputTo(PSE.Many(kind=:destination, within=PSE.SceneScope());
                        vars=(:energy,)),)),
            PSE.ModelSpec(GP.ChainStage{1,Float64,false}(0.5, 1.0);
                name=:column_stage, on=PSE.One(id=:column), every=Hour(1)),
        ), environment=(driver=1.0, duration=Hour(1)))
end

function run_inline_distributed_call_checks(; steps=2, regions_cases=(false, true))
    reports = NamedTuple[]
    @testset "inlined calls alongside validated distributed outputs" begin
        for regions in regions_cases
            reference = PSE.run!(call_distributed_fixture(); steps, outputs=:all)
            simulation = PSE.run!(call_distributed_fixture(); steps=0, outputs=:all)
            program = compile_regions(simulation; regions, resolved_calls=true,
                compact=regions, call_strategy=:inline)
            advance_regions!(program; steps)
            @test isequal(downstream_fingerprint(simulation),
                downstream_fingerprint(reference))
            @test PSE.final_state(simulation, :controller).inline_observed == 7.0
            @test PSE.final_state(simulation, :call_worker).value == 7.0
            @test PSE.final_state(simulation, :call_worker).visits == steps
            @test PSE.final_state(simulation, :owner).visits == steps
            @test PSE.final_state(simulation, :owner).rejected
            @test PSE.final_state(simulation, :owner).unchanged_after_rejection
            @test PSE.final_state(simulation, :unit_a).energy == 10.0 + steps
            @test PSE.final_state(simulation, :unit_b).energy == 20.0 + steps
            report = region_report(program)
            @test fast_call_count(report) == steps
            @test call_report_metric(report, :fallback_calls) == 0
            @test selected_region_count(report) == (regions ? 1 : 0)
            push!(reports, (; regions, report))
        end
    end
    return (; cases=length(reports), reports)
end
