using Statistics
using SHA

measurement_phase(m) = (
    seconds=m.time, allocated_bytes=m.bytes, gc_seconds=m.gctime,
    compilation_seconds=hasproperty(m, :compile_time) ? m.compile_time : nothing,
    recompilation_seconds=hasproperty(m, :recompile_time) ? m.recompile_time : nothing,
)

function portable_downstream_snapshot(simulation)
    observed = downstream_fingerprint(simulation)
    states = [(id=repr(id.value), fields=sort!([
        (name=string(name), type=string(typeof(value)), value=repr(value))
        for (name, value) in pairs(state)]; by=x -> x.name))
        for (id, state) in observed.states]
    sort!(states; by=x -> x.id)
    history = sort!([(key=repr(key), samples=repr(value))
        for (key, value) in observed.histories]; by=x -> x.key)
    return (; step=observed.step, states, history)
end

downstream_digest(simulation) = bytes2hex(sha256(repr(portable_downstream_snapshot(simulation))))

"""Counts active root rows/contexts separately from the model's semantic graph."""
function runtime_payload_counts(simulation)
    plan = simulation.execution_plan
    logical_targets = 0
    rich_targets = 0
    column_memberships = 0
    context_slots = 0
    unknown_target_views = 0
    for batch in plan.batches
        hasproperty(batch, :targets) || continue
        logical_targets += length(batch.targets)
        if isdefined(@__MODULE__, :RegionColumnBatch) && batch isa RegionColumnBatch
            # RegionTargetView is a public logical inspection view. Iterating it
            # reconstructs rich targets/contexts and would contaminate later GC
            # and memory measurements. Its length is safe and does no work.
            column_memberships += length(batch.targets)
            context_slots += 1
        elseif batch.targets isa Vector
            rich_targets += length(batch.targets)
            context_slots += length(batch.targets)
        else
            # An unrecognized lazy target view is not inspected implicitly.
            unknown_target_views += 1
        end
    end
    return (flat_root_logical_targets=logical_targets,
        retained_flat_rich_targets=rich_targets,
        column_target_memberships=column_memberships,
        retained_root_context_slots=context_slots,
        context_count_meaning=:payload_slots_not_recursive_unique_context_census,
        uninspected_lazy_target_views=unknown_target_views,
        flat_batches=length(plan.batches),
        semantic_status_views=length(simulation.compiled.status_views_by_target))
end

function measure_downstream_sample(fixture, variant::Symbol; outputs=:none,
    compact=true, measure_retained=false)
    construction = @timed fixture.builder()
    model = construction.value
    initial_ids = collect(PSE.object_ids(model))
    preparation = @timed PSE.run!(model; steps=0, outputs)
    simulation = preparation.value
    before = runtime_payload_counts(simulation)
    lowering = @timed prepare_backend(simulation, variant; compact)
    program = lowering.value
    after = runtime_payload_counts(simulation)
    execution = @timed advance_backend!(simulation, program; steps=fixture.steps)
    digest = downstream_digest(simulation)
    work = downstream_work_report(simulation, initial_ids)
    report = isnothing(program) ? (strategy=:executor,) : region_report(program)
    if !isnothing(program)
        assert_downstream_selection(fixture.kind, variant, report)
    end
    retained = measure_retained ? (
        simulation_bytes=Base.summarysize(simulation),
        program_including_simulation_bytes=isnothing(program) ?
            Base.summarysize(simulation) : Base.summarysize(program),
        meaning=:reachable_object_size_not_peak_RSS,
    ) : nothing
    phases = (construction=measurement_phase(construction),
        preparation=measurement_phase(preparation), lowering=measurement_phase(lowering),
        execution=measurement_phase(execution))
    return (; variant, phases, digest, work, report, payloads=(before, after), retained,
        complete_seconds=sum(p.seconds for p in values(phases)),
        complete_allocated_bytes=sum(p.allocated_bytes for p in values(phases)))
end

"""Warm serial samples; parity and diagnostics occur outside timed regions."""
function screen_downstream(fixture; variants=BACKEND_VARIANTS, repetitions=3,
    outputs=:none, compact=true, pre_sample_gc=true, measure_retained=false)
    repetitions > 0 || error("repetitions must be positive")
    :executor in variants || error("Include the unchanged executor in every screen")
    warmups = [measure_downstream_sample(fixture, variant; outputs, compact,
        measure_retained=false) for variant in variants]
    expected = only(filter(x -> x.variant === :executor, warmups)).digest
    all(x -> x.digest == expected, warmups) || error("Warmup full-state/history mismatch")
    records = NamedTuple[]
    for cycle in 1:repetitions
        for variant in (isodd(cycle) ? variants : reverse(variants))
            pre_sample_gc && GC.gc()
            record = measure_downstream_sample(fixture, variant; outputs, compact,
                measure_retained=measure_retained && cycle == 1)
            record.digest == expected || error("Measured state/history mismatch for $(variant)")
            push!(records, (; cycle, record...))
        end
    end
    return (; fixture=(kind=fixture.kind, steps=fixture.steps, metadata=fixture.metadata),
        outputs, repetitions, pre_sample_gc, compact, warmups, samples=records,
        baseline=:normal_executor_in_loaded_engine,
        environment=(julia=string(VERSION), cpu=Sys.CPU_NAME,
            package_path=Base.pathof(PSE), package_version=string(Base.pkgversion(PSE)),
            active_project=Base.active_project(), threads=Threads.nthreads()))
end

function summarize_downstream(screen)
    baseline = Dict(row.cycle => row for row in screen.samples if row.variant === :executor)
    return [begin
        rows = filter(row -> row.variant === variant, screen.samples)
        ratios = [(execution=row.phases.execution.seconds /
            baseline[row.cycle].phases.execution.seconds,
            complete=row.complete_seconds / baseline[row.cycle].complete_seconds)
            for row in rows]
        (variant,
            execution_seconds=median(row.phases.execution.seconds for row in rows),
            complete_seconds=median(row.complete_seconds for row in rows),
            complete_allocated_bytes=median(row.complete_allocated_bytes for row in rows),
            execution_allocated_bytes=median(row.phases.execution.allocated_bytes for row in rows),
            execution_ratio=median(row.execution for row in ratios),
            complete_ratio=median(row.complete for row in ratios), cycle_ratios=ratios,
            report=first(rows).report, work=first(rows).work,
            payloads=first(rows).payloads, retained=first(rows).retained)
    end for variant in unique(row.variant for row in screen.samples)]
end
