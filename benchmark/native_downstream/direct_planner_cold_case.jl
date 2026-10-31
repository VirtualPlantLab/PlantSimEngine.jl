# One arm in a newly started Kaimon worker; no prior simulations or IR probes.
for name in (:direct_case_kind, :direct_case_arm, :direct_case_freshness,
    :direct_case_output_path)
    isdefined(Main, name) || error("Missing cold experiment configuration: $name")
end
direct_case_freshness.new_process && direct_case_freshness.pid == getpid() ||
    error("Use a separate fresh Kaimon worker per cold arm")

let started = time_ns()
    include(joinpath(@__DIR__, "load_direct_planner_experiment.jl"))
    global direct_case_loader_seconds = (time_ns() - started) / 1e9
end

direct_case_record = Base.invokelatest(
    DirectPlannerMeasurements.run_direct_planner_case,
    direct_case_kind, direct_case_arm;
    steps=2, nobjects=2, outputs=:none, freshness=direct_case_freshness,
    progress_path=direct_case_output_path * ".pid$(getpid()).stages.tsv")

# Science snapshots, coverage and provenance follow all measured phases.
direct_case_provenance = NativeDownstreamMeasurements.process_provenance(
    packages=(PlantSimEngine, PlantBiophysics, XPalm, PlantGeom))
open(direct_case_output_path, "w") do io
    PlantSimEngine.JSON.print(io, (
        loader_seconds=direct_case_loader_seconds,
        loader_scope=:experimental_modules_after_Kaimon_project_import,
        record=direct_case_record, provenance=direct_case_provenance), 2)
end
