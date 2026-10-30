# Run one arm in a fresh Kaimon-controlled process, with no prior scientific
# case execution or IR probes. Disk precompile caches remain in place.
isdefined(Main, :preparation_cold_freshness) || error("Fresh-process attestation required")
preparation_cold_freshness.new_process &&
    preparation_cold_freshness.pid == Base.getpid() &&
    preparation_cold_freshness.pid != preparation_cold_freshness.previous_pid ||
    error("A distinct fresh process is required")
isdefined(Main, :preparation_cold_arm) || error("Choose one preparation arm")
isdefined(Main, :preparation_cold_package) || error("Choose :pb or :xp")
let started=time_ns()
    include(joinpath(@__DIR__, "load_preparation_experiment.jl"))
    global preparation_cold_loader_seconds=(time_ns()-started)/1e9
end
preparation_cold_spec = if preparation_cold_package === :pb
    PreparationReuseMeasurements.register_preparation_pb_case!(:preparation_cold_pb;
        nobjects=2, steps=2, outputs=:none)
elseif preparation_cold_package === :xp
    # Keep the same four-row forcing/backend as the warm growth fixture while
    # measuring only the first day and first birth, avoiding a singleton-source
    # special case as well as a longer cold simulation.
    base=PreparationReuseMeasurements.register_preparation_xp_case!(:preparation_cold_xp;
        steps=4, outputs=:none)
    M.register_case!(base.name; replace=true,
        config=(;base.config..., steps=1, forcing_rows=4),
        construct=base.construct, prepare=base.prepare, lower=base.lower,
        execute! =base.execute!, fingerprint=base.fingerprint,
        coverage=base.coverage, work=base.work,
        packages=base.packages, variants=base.variants)
else
    error("Unknown package")
end
preparation_cold_record=M.measure_case(preparation_cold_spec, preparation_cold_arm;
    temperature=:first_use, freshness=preparation_cold_freshness,
    measure_retained=false)
preparation_cold_path=joinpath(@__DIR__, "results", "preparation-reuse",
    "cold-$(preparation_cold_package)-$(preparation_cold_arm).json")
open(preparation_cold_path,"w") do io
    PlantSimEngine.JSON.print(io,(
        loader_seconds=preparation_cold_loader_seconds,
        loader_scope=:experimental_loader_after_Kaimon_project_import,
        record=preparation_cold_record),2)
end
