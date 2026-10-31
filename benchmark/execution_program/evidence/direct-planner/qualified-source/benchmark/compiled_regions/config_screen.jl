# Additional explicit configurations, without changing the frozen initial screen.

function measure_configured_sample(fixture, configuration; outputs=:none,
    measure_retained=false)
    construction = @timed fixture.builder()
    model = construction.value
    initial_ids = collect(PSE.object_ids(model))
    preparation = @timed PSE.run!(model; steps=0, outputs)
    simulation = preparation.value
    before = runtime_payload_counts(simulation)
    lowering = @timed (isnothing(configuration.options) ? nothing :
        compile_regions(simulation; configuration.options...))
    program = lowering.value
    after = runtime_payload_counts(simulation)
    execution = @timed advance_backend!(simulation, program; steps=fixture.steps)
    digest = downstream_digest(simulation)
    work = downstream_work_report(simulation, initial_ids)
    report = isnothing(program) ? (strategy=:executor,) : region_report(program)
    if !isnothing(program)
        if fixture.kind === :plantbiophysics && configuration.options.resolved_calls
            fast_call_count(report) > 0 || error("No resolved call executed")
        elseif fixture.kind === :xpalm && configuration.options.regions
            report.column_row_executions > 0 || error("No numerical region executed")
        end
    end
    retained = measure_retained ? (
        simulation_bytes=Base.summarysize(simulation),
        program_including_simulation_bytes=Base.summarysize(
            isnothing(program) ? simulation : program),
        meaning=:reachable_object_size_not_peak_RSS,
    ) : nothing
    phases = (construction=measurement_phase(construction),
        preparation=measurement_phase(preparation), lowering=measurement_phase(lowering),
        execution=measurement_phase(execution))
    return (; variant=configuration.name, configuration, digest, phases, work,
        report, payloads=(before, after), retained,
        complete_seconds=sum(p.seconds for p in values(phases)),
        complete_allocated_bytes=sum(p.allocated_bytes for p in values(phases)))
end

"""Warm serial comparison of named backend options, with exact full-state/history parity."""
function screen_configurations(fixture; configurations, repetitions=3,
    outputs=:none, measure_retained=false)
    repetitions > 0 || error("repetitions must be positive")
    count(configuration -> isnothing(configuration.options), configurations) == 1 ||
        error("Exactly one unchanged executor control is required")
    warmups = [measure_configured_sample(fixture, configuration; outputs)
        for configuration in configurations]
    expected = only(row for row in warmups if isnothing(row.configuration.options)).digest
    all(row -> row.digest == expected, warmups) || error("Configuration warmup parity failed")
    samples = NamedTuple[]
    for cycle in 1:repetitions
        for configuration in (isodd(cycle) ? configurations : reverse(configurations))
            GC.gc()
            record = measure_configured_sample(fixture, configuration; outputs,
                measure_retained=measure_retained && cycle == 1)
            record.digest == expected || error("Configuration parity failed: $(configuration.name)")
            push!(samples, (; cycle, record...))
        end
    end
    return (; fixture=(kind=fixture.kind, steps=fixture.steps, metadata=fixture.metadata),
        configurations, outputs, repetitions, pre_sample_gc=true, warmups, samples,
        baseline=:normal_executor_in_loaded_engine,
        environment=(julia=string(VERSION), cpu=Sys.CPU_NAME,
            package_path=Base.pathof(PSE), package_version=string(Base.pkgversion(PSE)),
            active_project=Base.active_project(), threads=Threads.nthreads()))
end
