# One case in a distinct Kaimon worker, before any scientific case or IR probe.
for name in (:future_case_kind, :future_case_arm, :future_case_freshness,
    :future_case_output_path)
    isdefined(Main, name) || error("Missing cold experiment configuration: $name")
end
future_case_freshness.new_process &&
    future_case_freshness.pid == Base.getpid() &&
    future_case_freshness.pid != future_case_freshness.previous_pid ||
    error("Use one distinct fresh Kaimon process per cold arm")

let started=time_ns()
    include(joinpath(@__DIR__, "load_experiments.jl"))
    include(joinpath(@__DIR__, "load_future_layout_experiment.jl"))
    global future_case_loader_seconds=(time_ns()-started)/1e9
end

future_case_record=Base.invokelatest(
    FutureLayoutMeasurements.run_future_layout_case, future_case_kind,
    future_case_arm; steps=2, outputs=:none, record_types=false,
    max_requests=12, status_max_requests=2, freshness=future_case_freshness,
    progress_path=future_case_output_path * ".pid$(Base.getpid()).stages.tsv")

# Provenance and complete semantic/type diagnostics follow all timed phases.
future_case_provenance=NativeDownstreamMeasurements.process_provenance(
    packages=(PlantSimEngine, PlantBiophysics, XPalm, PlantGeom))
open(future_case_output_path, "w") do io
    PlantSimEngine.JSON.print(io, (
        loader_seconds=future_case_loader_seconds,
        loader_scope=:experimental_modules_after_Kaimon_project_import,
        record=future_case_record, provenance=future_case_provenance), 2)
end
