module TightNativeGapBenchmarks

using Test,PlantSimEngine
const PSE=PlantSimEngine
const M=Main.NativeDownstreamMeasurements
const BaseGap=Main.TightGapBenchmarks
const Tight=Main.TightCallProgram
const Native=Main.NativePBDriver
const CR=Main.CompiledRegionsExperiment

export register_tight_native_gap_case!,tight_native_gap_preflight

function _native_payload(program)
    for row in eachindex(program.rows.ids)
        view=program.views[row]
        view isa Native.NativeStatusView || return false
        isempty(view.columns) && return false
        for (index,name) in enumerate(keys(view.columns))
            reference=PSE.refvalue(program.rows.statuses[row],name)
            reference isa Base.RefArray || return false
            getfield(reference,:x)===getfield(view.columns,index) || return false
            getfield(reference,:i)==getfield(view.indices,index) || return false
        end
    end
    return all(_native_payload,values(program.children))
end

"""
Use the existing observed batch-entry counter, with no timed probes or inferred
child work. This fixed fixture must have exactly one Tight batch, so a positive
entry count identifies that exact typed payload. Check its canonical columns
and numerical root protocol after execution. The field count is root interface
WIDTH ONCE; optimized/native units are observed BATCH ENTRIES, never fabricated
root/child execution counts. Actual children remain an instrumented companion.
"""
function _native_boundary_coverage(simulation,fixture)
    fixture.model.status_storage isa PSE.NativeColumnStorage ||
        throw(ArgumentError("Native arm has no canonical native storage"))
    report=Tight.tight_call_report(simulation)
    batches=[batch for batch in simulation.execution_plan.batches if batch isa Tight.TightBatch]
    length(batches)==report.tight_batches_prepared==1 ||
        throw(ArgumentError("Native boundary proof requires exactly one identified Tight batch"))
    report.tight_batch_executions>0 || throw(ArgumentError("No Tight batch entered"))
    iszero(report.fallback_batch_executions) || throw(ArgumentError("Native task fell back"))
    iszero(report.full_shared_numerical_roots) || throw(ArgumentError("Native task used Shared numeric roots"))
    batch=only(batches)
    batch.active[] || throw(ArgumentError("Tight batch retired before native coverage"))
    PSE.current_step(simulation)>0 && batch.last_time[]>0 ||
        throw(ArgumentError("Native task has no completed numerical epoch"))
    _native_payload(batch.frame.program) ||
        throw(ArgumentError("Executed batch payload is not bound to native canonical columns"))
    program=batch.frame.program
    context=Tight.TightContext(batch.frame,1,batch.last_time[],simulation.constants,
        Tight._header(batch.headers,1),nothing)
    status=Tight._status(context,Tight._model(batch.frame,1))
    status isa Native.NativeDirectStatus ||
        throw(ArgumentError("Executed batch root protocol is not native direct status"))
    fields=length(getfield(getfield(status,:view),:columns))
    fields>0 || throw(ArgumentError("Executed native root interface is empty"))
    entries=report.tight_batch_executions
    return (native_fields=fields,driver_units=entries,native_driver_units=entries,
        report,native_selection=(scope=:sole_observed_entered_tight_batch,
            root_field_width_once=fields,observed_batch_entries=entries,
            canonical_ref_bindings_verified=true,root_status_protocol=:native_direct_status,
            actual_child_counts=:not_collected_in_timed_arm),
        qualification=:actual_batch_entries_with_exact_native_payload_invariant)
end

function register_tight_native_gap_case!(name::Symbol;
    nobjects=2,steps=2,include_native_executor=true,replace=false)
    base=BaseGap.register_tight_gap_case!(name;nobjects,steps,replace)
    variants=M.VariantSpec[base.variants...]
    include_native_executor && push!(variants,M.VariantSpec(:native_executor;native=true))
    push!(variants,M.VariantSpec(:tight_native_projected;native=true,driver=true))
    push!(variants,M.VariantSpec(:tight_native_union;native=true,driver=true))
    tight_native(variant)=variant.name in (:tight_native_projected,:tight_native_union)
    native(variant)=tight_native(variant) || variant.name===:native_executor
    return M.register_case!(name;replace=true,config=base.config,packages=base.packages,
        variants=Tuple(variants),
        construct=(config,variant)->native(variant) ?
            Native.pb_native_fixture(;native=true,nobjects=config.nobjects,steps=config.steps) :
            base.construct(config,variant),
        prepare=(fixture,config,variant)->tight_native(variant) ?
            Tight.prepare_tight_calls(fixture.model;steps=0,outputs=:none,state_strategy=:native,
                count_calls=false,header_strategy=variant.name===:tight_native_union ? :same_object_union : :projected) :
            variant.name===:native_executor ? PSE.run!(fixture.model;steps=0,outputs=:none) :
            base.prepare(fixture,config,variant),
        lower=base.lower,execute! =base.execute!,fingerprint=base.fingerprint,
        coverage=(simulation,program,fixture,config,variant)->begin
            tight_native(variant) && return _native_boundary_coverage(simulation,fixture)
            if variant.name===:native_executor
                PSE.current_step(simulation)>0 || error("Native ordinary task did not advance")
                return (native_fields=PSE.native_storage_report(fixture.model).active_native_fields,
                    driver_units=0,native_driver_units=0,
                    qualification=:ordinary_executor_with_native_canonical_storage_after_execution)
            end
            return base.coverage(simulation,program,fixture,config,variant)
        end,work=base.work)
end

function tight_native_gap_preflight(;nobjects=2,steps=2)
    reports=Any[]
    @testset "Counter-free native batch boundary proof and actual-work companion" begin
        for header_strategy in (:projected,:same_object_union)
            reference=PSE.run!(Native.pb_native_fixture(;native=false,nobjects,steps).model;
                steps=steps,outputs=:none)
            fixture=Native.pb_native_fixture(;native=true,nobjects,steps)
            candidate=Tight.prepare_tight_calls(fixture.model;steps,outputs=:none,
                state_strategy=:native,header_strategy,count_calls=false)
            @test isequal(CR.portable_downstream_snapshot(candidate),CR.portable_downstream_snapshot(reference))
            coverage=_native_boundary_coverage(candidate,fixture)
            @test coverage.native_fields>0
            @test coverage.driver_units==coverage.native_driver_units==steps
            @test ismissing(coverage.report.executed_numerical_calls)
            companion=Tight.prepare_tight_calls(
                Native.pb_native_fixture(;native=true,nobjects,steps).model;
                steps,outputs=:none,state_strategy=:native,header_strategy,count_calls=true)
            @test isequal(CR.portable_downstream_snapshot(companion),CR.portable_downstream_snapshot(reference))
            work=Tight.tight_call_report(companion)
            @test work.executed_numerical_roots==nobjects*steps
            @test work.executed_numerical_calls>0
            @test work.executed_native_column_fields>0
            @test work.fallback_batch_executions==0
            push!(reports,(;header_strategy,coverage,actual_work_companion=work))
        end
        # Reference carriers must fail the native gate even when the driver
        # really entered and all scientific results are numerically correct.
        fixture=Native.pb_native_fixture(;native=false,nobjects,steps)
        reference_driver=Tight.prepare_tight_calls(fixture.model;steps,outputs=:none,
            state_strategy=:references,count_calls=false)
        @test_throws ArgumentError _native_boundary_coverage(reference_driver,fixture)
    end
    return (;passed=true,reports)
end

end
