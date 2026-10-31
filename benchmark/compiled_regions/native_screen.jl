# Additive diagnostic, included inside CompiledRegionsExperiment after measurements.
# Compare state ownership and execution independently in the SAME coupled scenario.
# The ordinary and column cases execute the same scientific model methods.

const NATIVE_SCREEN_VARIANTS = (:reference_executor, :reference_regions,
    :native_executor, :native_regions)

# Reference storage is the independent variable here. Keep the numeric element
# types, dimensions and every value in the comparison while normalizing the
# intentionally different RefVector{T,R} backing parameter.
_native_comparison_value(value) = value
_native_comparison_value(value::PSE.RefVector) = collect(value)
_native_comparison_value(value::PSE.ObjectRefVector) = collect(value)

function native_ownership_digest(simulation)
    observed = downstream_fingerprint(simulation)
    states = [(id=repr(id.value), fields=sort!([
        (name=string(name), type=string(typeof(_native_comparison_value(value))),
            value=repr(_native_comparison_value(value)))
        for (name, value) in pairs(state)]; by=x -> x.name))
        for (id, state) in observed.states]
    sort!(states; by=x -> x.id)
    history = sort!([(key=repr(key), samples=repr(value))
        for (key, value) in observed.histories]; by=x -> x.key)
    return bytes2hex(sha256(repr((; step=observed.step, states, history))))
end

function measure_native_screen_sample(variant; nobjects=128, nmodels=4,
    steps=256, value_type=Float64, outputs=:none, measure_retained=false)
    native = variant in (:native_executor, :native_regions)
    regions = variant in (:reference_regions, :native_regions)
    construction = @timed native_column_integration_fixture(value_type;
        native, nobjects, nmodels)
    fixture = construction.value
    preparation = @timed PSE.run!(fixture.model; steps=0, outputs)
    simulation = preparation.value
    lowering = @timed (regions ? compile_regions(simulation;
        regions=true, resolved_calls=false, compact=true) : nothing)
    program = lowering.value
    execution = @timed advance_backend!(simulation, program; steps)
    digest = native_ownership_digest(simulation)
    retained = measure_retained ? (
        simulation_bytes=Base.summarysize(simulation),
        program_including_simulation_bytes=Base.summarysize(
            isnothing(program) ? simulation : program),
        meaning=:reachable_object_size_not_peak_RSS,
    ) : nothing
    phases = (construction=measurement_phase(construction),
        preparation=measurement_phase(preparation),
        lowering=measurement_phase(lowering), execution=measurement_phase(execution))
    report = isnothing(program) ? (strategy=:executor,) : region_report(program)
    if regions
        report.column_row_executions > 0 || error("No numerical region executed")
        native && report.native_column_fields == 0 && error("No native column selected")
    end
    return (; variant, digest, phases, report, retained,
        complete_seconds=sum(p.seconds for p in values(phases)),
        complete_allocated_bytes=sum(p.allocated_bytes for p in values(phases)))
end

"""A small coupled chain with a live One consumer and an ordered Many reduction."""
function screen_native_ownership(; nobjects=128, nmodels=4, steps=256,
    value_type=Float64, outputs=:none, repetitions=3, measure_retained=true)
    variants = NATIVE_SCREEN_VARIANTS
    options = (; nobjects, nmodels, steps, value_type, outputs)
    warmups = [measure_native_screen_sample(variant; options...) for variant in variants]
    expected = first(warmups).digest
    all(row -> row.digest == expected, warmups) || error("Native warmup parity failed")
    samples = NamedTuple[]
    for cycle in 1:repetitions
        for variant in (isodd(cycle) ? variants : reverse(variants))
            GC.gc()
            record = measure_native_screen_sample(variant; options...,
                measure_retained=measure_retained && cycle == 1)
            record.digest == expected || error("Native sample parity failed: $(variant)")
            push!(samples, (; cycle, record...))
        end
    end
    return (; fixture=(nobjects, nmodels, steps, value_type=string(value_type),
            one_consumers=1, many_reductions=1), outputs, repetitions, warmups, samples,
        comparison=:numeric_types_values_histories_and_logical_carriers,
        environment=(julia=string(VERSION), cpu=Sys.CPU_NAME,
            package_path=Base.pathof(PSE), threads=Threads.nthreads()))
end
