module NewbornPreparationBenchmarks

using PlantSimEngine
const PSE = PlantSimEngine
const M = Main.NativeDownstreamMeasurements
const XP = Main.NativeXPDriver
const NP = Main.NewbornPreparation

export register_newborn_xp_case!

_growth() = getfield(Main, :LeanNativeGrowth)
_uses_preparation(variant) = variant.name in
    (:newborn_preparation, :incremental_reference_newborn)
_uses_growth(variant) = variant.name in
    (:incremental_reference, :incremental_reference_newborn)

"""
    register_newborn_xp_case!(name=:newborn_xp_small; steps=4, outputs=:none,
        include_incremental=true, replace=false)

Register independently constructed XPalm arms with ordinary canonical reference
storage: ordinary execution, newborn binding promotion alone, and optionally the
incremental reference driver alone and combined. All imports and weather loading
precede timing. Preparation contains zero-step logical/runtime compilation and
any backend construction; every arm continues through the public ordinary API.

Coverage requires actual promoted input bindings in enabled promotion arms and
proven newborn driver work in incremental arms. Promotion is compiler metadata
reuse, so it never claims optimized numerical executions or native column work.
Use the existing measurement harness for warm alternating screens; no benchmarks
run automatically when this helper loads or registers a case.
"""
function register_newborn_xp_case!(name::Symbol=:newborn_xp_small;
    steps::Int=4, outputs=:none, include_incremental::Bool=true,
    emission_speed::Real=0.2, seed::Int=1, replace::Bool=false)
    include_incremental && !isdefined(Main, :LeanNativeGrowth) &&
        error("Load lean_growth.jl first, or pass include_incremental=false")
    base = XP.register_xp_case!(name; steps, outputs, emission_speed, seed, replace)
    variants = M.VariantSpec[
        M.VariantSpec(:reference_executor),
        M.VariantSpec(:newborn_preparation),
    ]
    if include_incremental
        push!(variants, M.VariantSpec(:incremental_reference; driver=true))
        push!(variants, M.VariantSpec(:incremental_reference_newborn; driver=true))
    end
    return M.register_case!(name; config=base.config, packages=base.packages,
        replace=true, variants=Tuple(variants), construct=base.construct,
        prepare=(fixture, config, variant) -> begin
            _uses_preparation(variant) && NP.enable_newborn_preparation!(fixture.model)
            return _uses_growth(variant) ? _growth().prepare_growth(fixture.model;
                steps=0, outputs=config.outputs, state_strategy=:references) :
                PSE.run!(fixture.model; steps=0, outputs=config.outputs)
        end,
        lower=(simulation, fixture, config, variant) -> nothing,
        execute! = (simulation, program, fixture, config, variant) ->
            PSE.continue!(simulation; steps=config.steps),
        fingerprint=base.fingerprint,
        coverage=(simulation, program, fixture, config, variant) -> begin
            fixture.model.status_storage === nothing || error(
                "Newborn promotion screen must retain ordinary reference storage")
            preparation = NP.newborn_preparation_report(simulation)
            if _uses_preparation(variant)
                preparation.promoted_bindings > 0 || error(
                    "Promotion arm saved no resolved newborn input bindings")
            end
            base_coverage = (native_fields=0, driver_units=0, native_driver_units=0,
                promoted_input_bindings=_uses_preparation(variant) ?
                    preparation.promoted_bindings : 0,
                preparation,
                storage=PSE.native_storage_report(fixture.model),
                qualification=_uses_preparation(variant) ?
                    :actual_newborn_logical_binding_promotion : :ordinary_reference_executor,
                extra_backend_lowering=false)
            _uses_growth(variant) || return base_coverage
            growth = _growth().growth_report(simulation)
            growth.incremental_refreshes > 0 && growth.full_invalidations == 0 ||
                error("Incremental reference arm lost its addition fast path")
            iszero(growth.executed_native_column_fields) &&
                iszero(growth.native_row_executions) &&
                iszero(growth.native_newborn_row_executions) &&
                iszero(growth.live_native_rows) || error(
                    "Reference-backed growth must claim no native work")
            initial_bound = growth.initial_skipped_rich_targets * config.steps
            newborn_lower_bound = growth.driver_row_executions - initial_bound
            newborn_lower_bound > 0 || error(
                "Incremental reference arm did not prove newborn driver work")
            return merge(base_coverage, (driver_units=growth.driver_row_executions,
                growth, initial_driver_row_execution_upper_bound=initial_bound,
                newborn_driver_units_lower_bound=newborn_lower_bound,
                newborn_bound_assumption=:initial_numerical_roots_run_at_most_once_per_base_step_without_manual_calls,
                qualification=_uses_preparation(variant) ?
                    :actual_binding_promotion_and_reference_newborn_driver_work :
                    :reference_newborn_driver_work))
        end,
        work=base.work)
end

end # module
