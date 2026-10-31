module TightGapBenchmarks

const M = Main.NativeDownstreamMeasurements
const Gap = Main.GapBenchmarks
const Boundaries = Main.PureJuliaBoundaries
const Tight = Main.TightCallProgram

export register_tight_gap_case!

"""Fixed-task screen; hot child counters are absent, audited in a companion.

The timed tight coverage counts actual entered batches only. It does not turn
prepared rows or a known fixture size into alleged observed child executions.
The noinline plain arm isolates the boundary from headers and PSE metadata.
"""
function register_tight_gap_case!(name::Symbol; nobjects=2, steps=2, replace=false)
    base = Gap.register_gap_pb_case!(name; nobjects, steps, include_native=false, replace)
    pure_variant = M.VariantSpec(:pure_julia)
    variants = (base.variants...,
        M.VariantSpec(:tight_projected; driver=true),
        M.VariantSpec(:tight_union; driver=true),
        M.VariantSpec(:pure_noinline))
    tight(v) = v.name in (:tight_projected, :tight_union)
    boundary(v) = v.name === :pure_noinline
    return M.register_case!(name; replace=true, config=base.config,
        packages=base.packages, variants,
        construct=(config, variant) -> base.construct(config,
            boundary(variant) ? pure_variant : variant),
        prepare=(fixture, config, variant) -> tight(variant) ?
            Tight.prepare_tight_calls(fixture.model; steps=0, outputs=:none,
                state_strategy=:references, count_calls=false,
                header_strategy=variant.name === :tight_union ? :same_object_union : :projected) :
            base.prepare(fixture, config, boundary(variant) ? pure_variant : variant),
        lower=base.lower,
        execute! = (simulation, program, fixture, config, variant) -> boundary(variant) ?
            Boundaries.advance_pure_noinline_pb!(simulation; steps=config.steps) :
            base.execute!(simulation, program, fixture, config, variant),
        fingerprint=base.fingerprint,
        coverage=(simulation, program, fixture, config, variant) -> begin
            if tight(variant)
                report = Tight.tight_call_report(simulation)
                report.tight_batch_executions > 0 || error("No tight batch entered")
                iszero(report.fallback_batch_executions) || error("Unexpected fallback in qualified task")
                return (native_fields=0, driver_units=report.tight_batch_executions,
                    native_driver_units=0, report,
                    qualification=:actual_batch_entries_counterfree_children_separately_work_checked)
            end
            coverage = base.coverage(simulation, program, fixture, config,
                boundary(variant) ? pure_variant : variant)
            boundary(variant) || return coverage
            return (; coverage..., child_boundary=:specialized_noinline_helper)
        end,
        work=base.work)
end

end
