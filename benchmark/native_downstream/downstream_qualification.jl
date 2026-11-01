module DownstreamQualification

using PlantSimEngine, Test
const PSE=PlantSimEngine
const M=Main.NativeDownstreamMeasurements
const BP=Main.BoundedPreparation
const GR=Main.GraphRowProjection
const TP=Main.TypedOutputPreparation

export ARMS, policy, prepare, register_case, screen, coverage
const ARMS=(:ordinary_a,:ordinary_b,:graph_only,:prep_candidate)
function policy(arm)
    arm in ARMS || throw(ArgumentError("Unknown downstream qualification arm"))
    bounded=arm in (:graph_only,:prep_candidate)
    return (;bounded,graph=bounded,typed_output=arm===:prep_candidate)
end

# Every arm executes the ordinary core numerical runtime. The candidate changes
# only cold metadata, graph projection and typed output-status preparation.
Base.@nospecializeinfer @noinline function prepare(model,arm,config;
    constants=PSE.PlantMeteo.Constants(),performance=false)
    @nospecialize model config
    selected=policy(arm)
    selected.bounded && BP.enable_bounded_preparation!(model)
    selected.graph && GR.enable_graph_row_projection!(model)
    selected.typed_output && TP.enable_typed_output_preparation!(model)
    return PSE.run!(model;steps=0,outputs=config.outputs,constants,performance)
end
function coverage(simulation,arm)
    selected=policy(arm)
    bounded=BP.bounded_preparation_report(simulation)
    graph=GR.graph_row_projection_report(simulation)
    typed=TP.typed_output_preparation_report(simulation)
    bounded.enabled===selected.bounded || error("Bounded preparation arm contamination")
    graph.enabled===selected.graph || error("Graph projection arm contamination")
    typed.enabled===selected.typed_output || error("Typed output preparation arm contamination")
    all(batch->batch isa PSE.CompiledExecutionBatch,simulation.execution_plan.batches) ||
        error("Preparation-only qualification acquired a custom numerical executor")
    selected.bounded && bounded.scene_entries<=0 && error("No actual bounded preparation")
    return (;native_fields=0,driver_units=0,native_driver_units=0,arm,policy=selected,
        executor=:ordinary_PSE_compiled_batches,bounded,graph,typed_output_preparation=typed,
        actual_projection_rows=graph.counters.rows_projected,
        actual_typed_objects=typed.counters.objects_prepared,
        admission_scope=:completed_preparation_counters_not_inferred_kernel_execution)
end
Base.@nospecializeinfer @noinline function _advance!(simulation,steps)
    @nospecialize simulation
    PSE.continue!(simulation;steps)
    return nothing
end
function _nested(Q,simulation,fixture,config)
    isdefined(Q,:nested_clocks) || return nothing
    return Base.invokelatest(getfield(Q,:nested_clocks),simulation,fixture,config)
end

"""Register fresh downstream scenes with separate construction/preparation clocks.

The fixture module owns complete scientific fingerprints and work counters.
Source freezing and verification occur outside all phase timers. Nested clocks
are diagnostics and are never subtracted to claim pure framework overhead.
"""
function register_case(name::Symbol,Q::Module;config=Base.invokelatest(Q.config),
    arms=ARMS,replace=false)
    all(arm->arm in arms,ARMS) || throw(ArgumentError("Include ordinary A/A and both preparation arms"))
    configuration=merge(config,(protocol=:ecosystem_preparation_qualification_v1,
        statistical_unit=:one_fresh_independent_scientific_scene,
        storage=:ordinary_canonical_references,
        executor=:ordinary_PSE_compiled_batches))
    return M.register_case!(name;config=configuration,replace,
        variants=Tuple(M.VariantSpec(arm) for arm in arms),packages=Base.invokelatest(Q.packages),
        construct=(config,variant)->Base.invokelatest(Q.construct,config),
        prepare=(fixture,config,variant)->Base.invokelatest(prepare,fixture.model,variant.name,config;
            constants=fixture.constants),
        lower=(simulation,fixture,config,variant)->nothing,
        execute! = (simulation,program,fixture,config,variant)->Base.invokelatest(_advance!,simulation,config.steps),
        fingerprint=(simulation,fixture,config)->Base.invokelatest(Q.fingerprint,simulation,fixture,config),
        coverage=(simulation,program,fixture,config,variant)->merge(
            Base.invokelatest(coverage,simulation,variant.name),
            (nested_clocks=Base.invokelatest(_nested,Q,simulation,fixture,config),)),
        work=(simulation,fixture,config)->Base.invokelatest(Q.work,simulation,fixture,config))
end
screen(spec;repetitions=2,measure_retained=false)=Base.invokelatest(M.screen_case,spec;
    baseline=:ordinary_a,repetitions,measure_retained)

end # module
