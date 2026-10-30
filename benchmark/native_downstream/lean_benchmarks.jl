module LeanNativeBenchmarks

using PlantSimEngine

const PSE = PlantSimEngine
const M = Main.NativeDownstreamMeasurements
const NG = Main.NativeGenericDriver
const NXP = Main.NativeXPDriver
const NPB = Main.NativePBDriver
const Lean = Main.LeanNativeCompiler

export register_lean_generic_case!, register_lean_xp_case!, register_lean_pb_case!,
    register_lean_width_cases!

const LEAN_VARIANTS = (
    M.VariantSpec(:reference_executor),
    M.VariantSpec(:native_executor; native=true),
    M.VariantSpec(:native_driver; native=true, driver=true),
    M.VariantSpec(:lean_reference; driver=true),
    M.VariantSpec(:lean_native; native=true, driver=true),
)

"""
Wrap an existing, independently constructed downstream case. The lean arm's
direct execution-plan construction is charged to `pse_preparation`; it does
not build the ordinary plan first and has no second lowering phase. Keeping
the established fixture, snapshot and work functions makes the old control
and typed driver exact comparators rather than separate reimplementations.

`require_lean_work=false` is reserved for an explicit ordinary-fallback check,
for example a scene consisting exclusively of unsupported hard-call models.
Such a case cannot establish a native-driver performance gain.
"""
function _register_lean_case!(base; require_lean_work::Bool=true)
    variants = require_lean_work ? LEAN_VARIANTS : (
        M.VariantSpec(:reference_executor),
        M.VariantSpec(:native_executor; native=true),
        M.VariantSpec(:native_driver; native=true, driver=true),
        M.VariantSpec(:lean_reference),
        M.VariantSpec(:lean_native; native=true),
    )
    return M.register_case!(base.name; config=base.config, replace=true,
        packages=base.packages, variants,
        construct=base.construct,
        prepare=(fixture, config, variant) -> variant.name in (:lean_reference, :lean_native) ?
            Lean.prepare_lean(fixture.model; steps=0, outputs=config.outputs,
                state_strategy=variant.name === :lean_native ? :native : :references) :
            base.prepare(fixture, config, variant),
        lower=(simulation, fixture, config, variant) -> variant.name in (:lean_reference, :lean_native) ?
            nothing : base.lower(simulation, fixture, config, variant),
        execute! = (simulation, program, fixture, config, variant) ->
            variant.name in (:lean_reference, :lean_native) ? PSE.continue!(simulation; steps=config.steps) :
            base.execute!(simulation, program, fixture, config, variant),
        fingerprint=base.fingerprint,
        coverage=(simulation, program, fixture, config, variant) -> begin
            if !(variant.name in (:lean_reference, :lean_native))
                return base.coverage(simulation, program, fixture, config, variant)
            end
            report = Lean.lean_report(simulation)
            native_fields = report.executed_native_column_fields
            if !require_lean_work && variant.needs_native && iszero(native_fields)
                # This branch labels storage-only execution truthfully. The
                # original fallback actually ran on the canonical cells.
                native_fields = PSE.current_step(simulation) > 0 ?
                    PSE.native_storage_report(fixture.model).active_native_fields : 0
            end
            return (native_fields,
                driver_units=report.driver_row_executions,
                native_driver_units=report.native_row_executions,
                report,
                storage=PSE.native_storage_report(fixture.model),
                extra_backend_lowering=false,
                qualification=require_lean_work ?
                    (variant.needs_native ? :executed_lean_native : :executed_lean_references) :
                    :ordinary_fallback_screen)
        end,
        work=base.work)
end

function register_lean_generic_case!(name::Symbol; kwargs...)
    base = NG.register_generic_case!(name; kwargs...)
    return _register_lean_case!(base)
end

function register_lean_xp_case!(name::Symbol; kwargs...)
    base = NXP.register_xp_case!(name; kwargs...)
    return _register_lean_case!(base)
end

function register_lean_pb_case!(name::Symbol; kwargs...)
    base = NPB.register_pb_measurement!(M; name, kwargs...)
    return _register_lean_case!(base; require_lean_work=false)
end

register_lean_width_cases!(; widths=(4, 16), kwargs...) = [
    register_lean_generic_case!(Symbol(:lean_width_, width);
        nobjects=4, nmodels=width, steps=1, kwargs...) for width in widths]

end # module
