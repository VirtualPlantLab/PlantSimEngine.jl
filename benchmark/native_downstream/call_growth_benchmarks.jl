module CallGrowthBenchmarks

using PlantSimEngine

const PSE = PlantSimEngine
const M = Main.NativeDownstreamMeasurements
const PB = Main.NativePBDriver
const XP = Main.NativeXPDriver
const Lean = Main.LeanNativeCompiler

export register_direct_call_case!, register_incremental_growth_case!

_direct_backend() = getfield(Main, :DirectCallCompiler)
_growth_backend() = getfield(Main, :LeanNativeGrowth)

function _ordinary_native_fields(simulation, fixture)
    PSE.current_step(simulation) > 0 || return 0
    fixture.model.status_storage isa PSE.NativeColumnStorage || return 0
    return PSE.native_storage_report(fixture.model).active_native_fields
end

function _lean_coverage(simulation, fixture)
    report = Lean.lean_report(simulation)
    fields = report.executed_native_column_fields
    return (native_fields=iszero(fields) ? _ordinary_native_fields(simulation, fixture) : fields,
        driver_units=report.driver_row_executions,
        native_driver_units=report.native_row_executions,
        report, storage=PSE.native_storage_report(fixture.model),
        qualification=iszero(report.driver_row_executions) ?
            :prior_lean_ordinary_fallback : :prior_lean_executed_work,
        extra_backend_lowering=false)
end

"""
    register_direct_call_case!(name; nobjects=2, steps=2, outputs=:none,
        include_reference_driver=true, include_previous_driver=false)

Register independently constructed original PlantBiophysics fixtures. The
direct compiler's full setup is timed as preparation; `lower` is empty for that
arm. Ordinary reference state, native storage with ordinary execution and the
prior lean compiler remain separate controls. Optional reference-backed direct
execution isolates the call compiler from native storage. The older two-stage
typed driver is opt-in so a small first screen does not compile unused arms.

Every direct arm must execute both real roots and children. A compiler request
that falls back completely cannot be reported as an optimized performance arm.
"""
function register_direct_call_case!(name::Symbol=:direct_call_small;
    nobjects::Int=2, steps::Int=2, outputs=:none, replace::Bool=false,
    include_reference_driver::Bool=true, include_previous_driver::Bool=false,
    status_strategy::Symbol=:direct)
    backend = _direct_backend()
    base = PB.register_pb_measurement!(M; name, nobjects, steps, outputs, replace,
        status_strategy)
    arms = M.VariantSpec[
        M.VariantSpec(:reference_executor),
        M.VariantSpec(:native_executor; native=true),
        M.VariantSpec(:prior_lean; native=true),
    ]
    include_previous_driver && push!(arms,
        M.VariantSpec(:previous_typed; native=true, driver=true))
    include_reference_driver && push!(arms,
        M.VariantSpec(:direct_reference; driver=true))
    push!(arms, M.VariantSpec(:direct_calls; native=true, driver=true))
    is_direct(variant) = variant.name in (:direct_calls, :direct_reference)
    return M.register_case!(name; config=base.config, replace=true,
        packages=base.packages, variants=Tuple(arms), construct=base.construct,
        prepare=(fixture, config, variant) ->
            is_direct(variant) ? backend.prepare_direct_calls(fixture.model;
                steps=0, outputs=config.outputs,
                state_strategy=variant.needs_native ? :native : :references,
                status_strategy=config.status_strategy) :
            variant.name === :prior_lean ? Lean.prepare_lean(fixture.model;
                steps=0, outputs=config.outputs) :
            base.prepare(fixture, config, variant),
        lower=(simulation, fixture, config, variant) ->
            variant.name === :previous_typed ?
                base.lower(simulation, fixture, config, variant) : nothing,
        execute! = (simulation, program, fixture, config, variant) ->
            variant.name === :previous_typed ?
                base.execute!(simulation, program, fixture, config, variant) :
                PSE.continue!(simulation; steps=config.steps),
        fingerprint=base.fingerprint,
        coverage=(simulation, program, fixture, config, variant) -> begin
            variant.name === :prior_lean && return _lean_coverage(simulation, fixture)
            if !is_direct(variant)
                return base.coverage(simulation, program, fixture, config, variant)
            end
            report = backend.direct_call_report(simulation)
            roots, children = report.executed_numerical_roots, report.executed_numerical_calls
            roots > 0 && children > 0 || error(
                "Direct call arm must execute optimized roots and child calls")
            fields = report.executed_native_column_fields
            !variant.needs_native && !iszero(fields) && error(
                "Reference-backed direct calls must not claim native column work")
            units = roots + children
            return (native_fields=fields, driver_units=units,
                native_driver_units=fields > 0 ? units : 0,
                direct_root_units=roots, direct_child_units=children,
                report, storage=PSE.native_storage_report(fixture.model),
                qualification=variant.needs_native ?
                    :executed_direct_calls_with_native_columns :
                    :executed_direct_calls_with_original_references,
                extra_backend_lowering=false)
        end,
        work=base.work)
end

"""
    register_incremental_growth_case!(name; steps=4, outputs=:none,
        include_reference_driver=false)

Register four independent original XPalm growth fixtures with identical seed,
weather and documented accelerated-emission parameters. CSV loading stays in
the established fixture registration, outside all measured phases. The new
arm must execute native newborn rows; counting allocated pools, refreshes or
initial native batches is insufficient to pass its coverage gate.

The optional reference-backed incremental driver separates refresh/lowering
from native storage. Its newborn coverage is a conservative lower bound:
driver rows beyond `initial_skipped_rich_targets * steps` must belong to new
objects, because these numerical roots have no hard calls and each initial
row runs at most once per base step. It never claims native execution.
"""
function register_incremental_growth_case!(name::Symbol=:incremental_growth_small;
    steps::Int=4, outputs=:none, replace::Bool=false,
    emission_speed::Real=0.2, seed::Int=1,
    include_reference_driver::Bool=false)
    backend = _growth_backend()
    base = XP.register_xp_case!(name; steps, outputs, replace, emission_speed, seed)
    arms = M.VariantSpec[
        M.VariantSpec(:reference_executor),
        M.VariantSpec(:native_executor; native=true),
        M.VariantSpec(:prior_lean; native=true, driver=true),
    ]
    include_reference_driver && push!(arms,
        M.VariantSpec(:incremental_reference; driver=true))
    push!(arms, M.VariantSpec(:incremental_growth; native=true, driver=true))
    is_incremental(variant) = variant.name in (:incremental_growth, :incremental_reference)
    return M.register_case!(name; config=base.config, replace=true,
        packages=base.packages, variants=Tuple(arms), construct=base.construct,
        prepare=(fixture, config, variant) ->
            is_incremental(variant) ?
                backend.prepare_growth(fixture.model; steps=0, outputs=config.outputs,
                    state_strategy=variant.needs_native ? :native : :references) :
            variant.name === :prior_lean ?
                Lean.prepare_lean(fixture.model; steps=0, outputs=config.outputs) :
            base.prepare(fixture, config, variant),
        lower=(simulation, fixture, config, variant) -> nothing,
        execute! = (simulation, program, fixture, config, variant) ->
            PSE.continue!(simulation; steps=config.steps),
        fingerprint=base.fingerprint,
        coverage=(simulation, program, fixture, config, variant) -> begin
            variant.name === :prior_lean && return _lean_coverage(simulation, fixture)
            if !is_incremental(variant)
                return base.coverage(simulation, program, fixture, config, variant)
            end
            report = backend.growth_report(simulation)
            report.incremental_refreshes > 0 || error(
                "Incremental growth arm performed no incremental refresh")
            if variant.name === :incremental_reference
                iszero(report.executed_native_column_fields) &&
                    iszero(report.native_row_executions) &&
                    iszero(report.native_newborn_row_executions) || error(
                    "Reference-backed incremental growth must claim no native work")
                initial_bound = report.initial_skipped_rich_targets * config.steps
                newborn_lower_bound = report.driver_row_executions - initial_bound
                newborn_lower_bound > 0 || error(
                    "Reference-backed growth did not prove newborn driver execution")
                return (native_fields=0, driver_units=report.driver_row_executions,
                    native_driver_units=0, native_newborn_units=0,
                    initial_driver_row_execution_upper_bound=initial_bound,
                    newborn_driver_units_lower_bound=newborn_lower_bound,
                    newborn_bound_assumption=:initial_numerical_roots_run_at_most_once_per_base_step_without_manual_calls,
                    report, storage=PSE.native_storage_report(fixture.model),
                    qualification=:reference_driver_growth_with_conservative_newborn_lower_bound,
                    extra_backend_lowering=false)
            end
            report.native_newborn_row_executions > 0 || error(
                "Incremental growth arm executed no native newborn row")
            return (native_fields=report.executed_native_column_fields,
                driver_units=report.driver_row_executions,
                native_driver_units=report.native_row_executions,
                native_newborn_units=report.native_newborn_row_executions,
                report, storage=PSE.native_storage_report(fixture.model),
                qualification=:executed_incremental_newborn_native_work,
                extra_backend_lowering=false)
        end,
        work=base.work)
end

end # module
