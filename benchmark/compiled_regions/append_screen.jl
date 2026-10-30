# Standalone additive driver. Include inside CompiledRegionsExperiment after
# measurements.jl. Executor, numerical kernels and existing screens are unchanged.

const APPEND_SCREEN_VARIANTS = (:executor, :reference_rebuild, :reference_append)

function _append_screen_advance!(simulation, program, nobjects, nmodels, steps)
    for step in 1:steps
        object_id = nobjects + step
        # Registration, Status construction and the resulting lifecycle work
        # all belong to execution cost in every arm.
        PSE.register_object!(simulation.model, PSE.Object(object_id;
            kind=:arbitrary_unit, scale=:unit,
            status=GP._chain_status(nmodels, Float64, 0, object_id)))
        if isnothing(program)
            PSE.continue!(simulation; steps=1)
        else
            advance_regions!(program; steps=1)
        end
    end
    return nothing
end

function measure_append_screen_sample(variant; nobjects=64, nmodels=2, steps=16,
    outputs=:none, measure_retained=false)
    variant in APPEND_SCREEN_VARIANTS || throw(ArgumentError("Unknown append screen arm."))
    construction = @timed GP.fixture_builder(; nobjects, nmodels,
        value_type=Float64, extras=0)
    model = construction.value
    initial_ids = collect(PSE.object_ids(model))
    preparation = @timed PSE.run!(model; steps=0, outputs)
    simulation = preparation.value
    before = runtime_payload_counts(simulation)
    lowering = @timed (variant === :executor ? nothing :
        compile_regions(simulation; regions=true, resolved_calls=false, compact=true,
            state_strategy=:references,
            refresh_strategy=variant === :reference_append ? :append : :rebuild))
    program = lowering.value
    after = runtime_payload_counts(simulation)
    execution = @timed _append_screen_advance!(simulation, program,
        nobjects, nmodels, steps)
    # Full typed final-state and raw-history parity is checked outside all
    # measured phases, using the same digest as the downstream harness.
    digest = downstream_digest(simulation)
    work = downstream_work_report(simulation, initial_ids)
    report = isnothing(program) ? (strategy=:executor,) : region_report(program)
    if !isnothing(program)
        report.column_row_executions > 0 || error("No numerical region executed")
    end
    if variant === :reference_append
        report.append_batch_commits > 0 || error("Append screen made no qualified append")
        report.append_row_memberships > 0 || error("Append screen added no region rows")
    end
    work.objects == nobjects + steps || error("Append screen object count differs")
    length(work.added_ids) == steps || error("Append screen registration count differs")
    retained = measure_retained ? (
        simulation_bytes=Base.summarysize(simulation),
        program_including_simulation_bytes=Base.summarysize(
            isnothing(program) ? simulation : program),
        meaning=:reachable_object_size_not_peak_RSS,
    ) : nothing
    phases = (construction=measurement_phase(construction),
        preparation=measurement_phase(preparation), lowering=measurement_phase(lowering),
        execution=measurement_phase(execution))
    return (; variant, phases, digest, work, report, payloads=(before, after), retained,
        complete_seconds=sum(phase.seconds for phase in values(phases)),
        complete_allocated_bytes=sum(phase.allocated_bytes for phase in values(phases)))
end

"""
    screen_append_growth(; nobjects=64, nmodels=2, steps=16, repetitions=3,
        outputs=:none, measure_retained=false)

Warm three arms, then alternate their order over paired serial cycles. Every
execution registers one initialized numeric-ID object before each step. The
append arm must report actual commits; no zero-hit fallback is called a win.
"""
function screen_append_growth(; nobjects=64, nmodels=2, steps=16, repetitions=3,
    outputs=:none, measure_retained=false)
    nobjects > 0 && nmodels > 0 && steps > 0 && repetitions > 0 ||
        throw(ArgumentError("Append screen dimensions and repetitions must be positive."))
    variants = APPEND_SCREEN_VARIANTS
    options = (; nobjects, nmodels, steps, outputs)
    warmups = [measure_append_screen_sample(variant; options...) for variant in variants]
    expected = only(row for row in warmups if row.variant === :executor).digest
    all(row -> row.digest == expected, warmups) || error("Append screen warmup parity failed")
    samples = NamedTuple[]
    for cycle in 1:repetitions
        for variant in (isodd(cycle) ? variants : reverse(variants))
            GC.gc()
            record = measure_append_screen_sample(variant; options...,
                measure_retained=measure_retained && cycle == 1)
            record.digest == expected || error("Append screen parity failed: $(variant)")
            push!(samples, (; cycle, record...))
        end
    end
    return (; fixture=(kind=:pure_addition_chain, nobjects, nmodels, steps,
            additions=steps, numeric_ids=true, initialized_statuses=true),
        variants, outputs, repetitions, pre_sample_gc=true, warmups, samples,
        registration_in_execution_phase=true,
        baseline=:normal_executor_in_loaded_engine,
        environment=(julia=string(VERSION), cpu=Sys.CPU_NAME,
            package_path=Base.pathof(PSE), package_version=string(Base.pkgversion(PSE)),
            active_project=Base.active_project(), threads=Threads.nthreads()))
end

"""Small view of the existing paired downstream summary, with append coverage."""
function summarize_append_screen(screen)
    return [(
        variant=row.variant,
        execution_seconds=row.execution_seconds,
        complete_seconds=row.complete_seconds,
        execution_allocated_bytes=row.execution_allocated_bytes,
        complete_allocated_bytes=row.complete_allocated_bytes,
        execution_ratio=row.execution_ratio,
        complete_ratio=row.complete_ratio,
        append_batch_commits=hasproperty(row.report, :append_batch_commits) ?
            row.report.append_batch_commits : 0,
        append_row_memberships=hasproperty(row.report, :append_row_memberships) ?
            row.report.append_row_memberships : 0,
        final_objects=row.work.objects,
        registered_objects=length(row.work.added_ids),
    ) for row in summarize_downstream(screen)]
end
