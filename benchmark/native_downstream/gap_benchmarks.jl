module GapBenchmarks

using PlantSimEngine
const PSE=PlantSimEngine
const M=Main.NativeDownstreamMeasurements
const PB=Main.NativePBDriver
const Pure=Main.PureJuliaReference
const Shared=Main.SharedCallProgram

export register_gap_pb_case!

function register_gap_pb_case!(name::Symbol; nobjects=2,steps=2,
    include_native=true,replace=false)
    base=Pure.register_pure_pb_case!(name;nobjects,steps,replace)
    variants=M.VariantSpec[M.VariantSpec(:reference_executor),
        M.VariantSpec(:direct_reference;driver=true),
        M.VariantSpec(:shared_reference;driver=true)]
    if include_native
        push!(variants,M.VariantSpec(:native_executor;native=true))
        push!(variants,M.VariantSpec(:shared_native;native=true,driver=true))
    end
    push!(variants,M.VariantSpec(:pure_julia))
    shared(v)=v.name in (:shared_reference,:shared_native)
    return M.register_case!(name;replace=true,config=base.config,
        packages=base.packages,variants=Tuple(variants),
        construct=(config,variant)->variant.name===:pure_julia ?
            base.construct(config,variant) : PB.pb_native_fixture(;
                native=variant.needs_native,nobjects=config.nobjects,steps=config.steps),
        prepare=(fixture,config,variant)->shared(variant) ?
            Shared.prepare_shared_calls(fixture.model;steps=0,outputs=:none,
                state_strategy=variant.needs_native ? :native : :references) :
            base.prepare(fixture,config,variant),
        lower=base.lower,execute! =base.execute!,fingerprint=base.fingerprint,
        coverage=(simulation,program,fixture,config,variant)->begin
            if shared(variant)
                report=Shared.shared_call_report(simulation)
                report.executed_numerical_roots>0 && report.executed_numerical_calls>0 ||
                    error("Shared arm executed no numerical roots/children")
                return (native_fields=report.executed_native_column_fields,
                    driver_units=report.executed_numerical_roots+report.executed_numerical_calls,
                    native_driver_units=variant.needs_native ?
                        report.executed_numerical_roots+report.executed_numerical_calls : 0,
                    report,qualification=:actual_shared_program_work)
            elseif variant.name===:native_executor
                return (native_fields=PSE.native_storage_report(fixture.model).active_native_fields,
                    driver_units=0,native_driver_units=0,
                    qualification=:ordinary_execution_with_native_canonical_storage)
            end
            return base.coverage(simulation,program,fixture,config,variant)
        end,work=base.work)
end

end
