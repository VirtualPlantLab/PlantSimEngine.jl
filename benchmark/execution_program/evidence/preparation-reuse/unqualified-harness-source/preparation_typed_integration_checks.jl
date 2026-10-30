module PreparationTypedIntegrationChecks

using PlantSimEngine, Test
const PSE = PlantSimEngine
const PB = Main.NativePBDriver
const CR = Main.CompiledRegionsExperiment
const Tight = Main.TightCallProgram
const Reuse = Main.PlanViewReuse
const Bounded = Main.BoundedPreparation
const M = Main.NativeDownstreamMeasurements

export preparation_typed_integration_checks, register_preparation_typed_case!

const _ARMS = (:reference_executor, :tight_only, :combined_prep_only, :combined_prep_tight)
_uses_preparation(arm) = arm in (:combined_prep_only, :combined_prep_tight)
_uses_tight(arm) = arm in (:tight_only, :combined_prep_tight)

function _prepare(model, arm; outputs=:none, count_calls=false)
    arm in _ARMS || throw(ArgumentError("Unknown preparation/typed arm: $arm"))
    model.status_storage === nothing || error("This comparison requires ordinary canonical references")
    if _uses_preparation(arm)
        Reuse.enable_plan_view_reuse!(model)
        Bounded.enable_bounded_preparation!(model)
    end
    return _uses_tight(arm) ? Tight.prepare_tight_calls(model;
        steps=0, outputs, state_strategy=:references, header_strategy=:projected,
        count_calls) : PSE.run!(model; steps=0, outputs)
end

function _preparation_coverage(simulation, enabled)
    reuse = Reuse.plan_view_reuse_report(simulation)
    bounded = Bounded.bounded_preparation_report(simulation)
    reused = reuse.recipe_hits + reuse.plain_preservations
    if enabled
        reused > 0 || error("Enabled preparation performed no metadata reuse")
        bounded.scene_entries > 0 && bounded.scenario_plans > 0 &&
            bounded.metadata_symbol_tables > 0 || error("Enabled preparation used no bounded factories")
    else
        iszero(reused) || error("Preparation control unexpectedly reused metadata")
        iszero(bounded.scene_entries) && iszero(bounded.scenario_plans) ||
            error("Preparation control unexpectedly used bounded factories")
    end
    return (; reuse, bounded, reused_metadata_operations=reused,
        qualification=:observed_metadata_operations_separate_from_numerical_work)
end

function _coverage(simulation, arm)
    preparation = _preparation_coverage(simulation, _uses_preparation(arm))
    if !_uses_tight(arm)
        return (native_fields=0, driver_units=0, native_driver_units=0,
            preparation, qualification=:ordinary_execution_with_recorded_preparation_policy)
    end
    report = Tight.tight_call_report(simulation)
    report.tight_batch_executions > 0 || error("No typed numerical batch entered")
    iszero(report.fallback_batch_executions) || error("Qualified task unexpectedly fell back")
    iszero(report.full_shared_numerical_roots) || error("Qualified task used full Shared numerical roots")
    return (native_fields=0, driver_units=report.tight_batch_executions,
        native_driver_units=0, preparation, typed=report,
        observed_unit=:entered_numerical_batches,
        qualification=:counterfree_typed_batches_with_separate_actual_work_companion)
end

"""Small original-kernel PB check of preparation policies and the typed executor.

Each arm owns independent scientific state. The two typed arms count actual
roots/children/lookups; the reference ordinary executor supplies full state and
retained-history parity. An escaped scalar Ref is also mutated between steps
in every arm, testing current canonical values as well as identity.
"""
function preparation_typed_integration_checks(; nobjects=2, steps=2)
    nobjects > 0 && steps > 0 || throw(ArgumentError("Positive objects/steps required"))
    reports = Any[]
    @testset "Preparation policies preserve original typed hard-call numerical work" begin
        for outputs in (:none, :all)
            simulations = Dict(arm => _prepare(
                PB.pb_native_fixture(; native=false, nobjects, steps).model,
                arm; outputs, count_calls=_uses_tight(arm)) for arm in _ARMS)
            ordinary = simulations[:reference_executor]
            statuses = Dict(arm => PSE.model_status(simulation.model, 1)
                for (arm, simulation) in simulations)
            escaped = Dict(arm => PSE.refvalue(status, :Ra_SW_f)
                for (arm, status) in statuses)
            for arm in _ARMS
                @test isequal(CR.downstream_fingerprint(simulations[arm]),
                    CR.downstream_fingerprint(ordinary))
                _preparation_coverage(simulations[arm], _uses_preparation(arm))
            end
            for step in 1:steps
                for arm in _ARMS
                    PSE.step!(simulations[arm])
                end
                expected = CR.downstream_fingerprint(ordinary)
                for arm in _ARMS
                    simulation = simulations[arm]
                    @test isequal(CR.downstream_fingerprint(simulation), expected)
                    @test PSE.model_status(simulation.model, 1) === statuses[arm]
                    @test PSE.refvalue(statuses[arm], :Ra_SW_f) === escaped[arm]
                    @test PSE.refvalue(PSE.model_status(simulation.model, 1), :Ra_SW_f) === escaped[arm]
                end
                if step < steps
                    for arm in _ARMS
                        escaped[arm][] += oftype(escaped[arm][], 1)
                    end
                end
            end
            control = Tight.tight_call_report(simulations[:tight_only])
            combined = Tight.tight_call_report(simulations[:combined_prep_tight])
            for report in (control, combined)
                @test report.count_calls
                @test report.executed_numerical_roots == nobjects * steps
                @test report.executed_numerical_calls > 0
                @test report.typed_model_lookups > 0
                @test report.tight_batch_executions == steps
                @test report.fallback_batch_executions == 0
                @test report.full_shared_numerical_roots == 0
                @test report.full_shared_numerical_calls == 0
                @test report.executed_native_column_fields == 0
                @test report.lazy_public_wrappers == 0
                @test report.constructed_rich_targets == 0
            end
            @test combined.executed_numerical_roots == control.executed_numerical_roots
            @test combined.executed_numerical_calls == control.executed_numerical_calls
            @test combined.typed_model_lookups == control.typed_model_lookups
            @test combined.executed_numerical_fields == control.executed_numerical_fields
            for arm in _ARMS
                coverage = _coverage(simulations[arm], arm)
                push!(reports, (; outputs, arm, coverage))
            end
        end
    end
    return (; passed=true, reports,
        interpretation=:original_PB_kernels_and_live_refs_with_independent_preparation_and_execution_policies)
end

"""Register a small four-arm warm comparison without executing it.

Preparation enablement and typed-plan construction remain inside the measured
preparation phase. Timed child counters are absent. Coverage records genuine
entered batches and metadata work; actual children belong to the check companion.
"""
function register_preparation_typed_case!(name::Symbol=:preparation_typed_small;
    nobjects::Int=2, steps::Int=2, outputs=:none, replace::Bool=false)
    config = (; nobjects, steps, outputs,
        mechanism=:combined_metadata_preparation_cross_typed_call_program)
    return M.register_case!(name; config, replace,
        packages=(PSE, PB.PB, PB.PlantMeteo),
        variants=Tuple(M.VariantSpec(arm; driver=_uses_tight(arm)) for arm in _ARMS),
        construct=(config, variant) -> begin
            fixture = PB.pb_native_fixture(; native=false,
                nobjects=config.nobjects, steps=config.steps)
            return (; fixture..., initial_ids=collect(PSE.object_ids(fixture.model)))
        end,
        prepare=(fixture, config, variant) -> _prepare(fixture.model, variant.name;
            outputs=config.outputs, count_calls=false),
        lower=(simulation, fixture, config, variant) -> nothing,
        execute! = (simulation, program, fixture, config, variant) ->
            PSE.continue!(simulation; steps=config.steps),
        fingerprint=(simulation, fixture, config) -> CR.portable_downstream_snapshot(simulation),
        coverage=(simulation, program, fixture, config, variant) ->
            _coverage(simulation, variant.name),
        work=(simulation, fixture, config) ->
            CR.downstream_work_report(simulation, fixture.initial_ids))
end

end # module
