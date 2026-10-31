# Deliberately usable with fixtures alone in the unchanged original checkout.
# No benchmark dependency or downstream environment mutation is necessary.

const SCREEN_ARMS = (
    (name=:executor, strategy=:executor, packed=false),
    (name=:typed, strategy=:typed, packed=false),
    (name=:fused, strategy=:fused, packed=false),
    (name=:packed, strategy=:typed, packed=true),
    (name=:fused_packed, strategy=:fused, packed=true),
    (name=:monolith, strategy=:monolith, packed=false),
    (name=:monolith_packed, strategy=:monolith, packed=true),
)

const SCALAR_ARMS = (
    (name=:scalar_fused, strategy=:fused, packed=false, scalar=true),
    (name=:scalar_fused_packed, strategy=:fused, packed=true, scalar=true),
    (name=:scalar_monolith, strategy=:monolith, packed=false, scalar=true),
    (name=:scalar_monolith_packed, strategy=:monolith, packed=true, scalar=true),
)

const REFINED_ARMS = (
    (name=:regular_typed, strategy=:typed, packed=false, regular=true),
    (name=:regular_monolith, strategy=:monolith, packed=false, regular=true),
    (name=:fast_scalar_monolith, strategy=:monolith, packed=false, fast=true),
    (name=:fast_scalar_monolith_packed, strategy=:monolith, packed=true, fast=true),
    (name=:regular_fast_scalar_monolith, strategy=:monolith, packed=false, fast=true, regular=true),
    (name=:prepared_typed, strategy=:typed, packed=false, prepared=true),
    (name=:prepared_regular_typed, strategy=:typed, packed=false, prepared=true, regular=true),
    (name=:prepared_regular_fast_scalar_packed, strategy=:monolith, packed=true, prepared=true, fast=true, regular=true),
)

const COLUMN_ARMS = (
    (name=:columns_typed, strategy=:typed, packed=true, columns=true),
    (name=:columns_fused, strategy=:fused, packed=true, columns=true),
    (name=:columns_monolith, strategy=:monolith, packed=true, columns=true),
    (name=:regular_columns_monolith, strategy=:monolith, packed=true, columns=true, regular=true),
    (name=:prepared_regular_columns_typed, strategy=:typed, packed=true, columns=true, regular=true, prepared=true),
    (name=:prepared_regular_columns_monolith, strategy=:monolith, packed=true, columns=true, regular=true, prepared=true),
)

const TEMPORAL_ARMS = (
    (name=:trajectories, strategy=:monolith, packed=true, temporal=true),
    (name=:prepared_trajectories, strategy=:monolith, packed=true, temporal=true, prepared=true),
)

@inline _experiment_flag(arm, key) = hasproperty(arm, key) && getproperty(arm, key)

function lower_experiment(sim, arm; block_size=4)
    _experiment_flag(arm, :temporal) && return compile_temporal_program(sim;
        prepared=_experiment_flag(arm, :prepared))
    program = if _experiment_flag(arm, :prepared)
        base = compile_prepared_program(sim; strategy=arm.strategy, packed=arm.packed, block_size)
        if _experiment_flag(arm, :columns)
            base.plan = _compile_column_plan(base)
            ColumnGeneratedProgram(base)
        elseif _experiment_flag(arm, :fast)
            base.plan = _compile_fast_scalar_plan(base)
            FastScalarGeneratedProgram(base)
        else
            base
        end
    elseif _experiment_flag(arm, :columns)
        compile_column_program(sim; strategy=arm.strategy, block_size)
    elseif _experiment_flag(arm, :fast)
        compile_fast_scalar_program(sim; strategy=arm.strategy, packed=arm.packed, block_size)
    elseif _experiment_flag(arm, :scalar)
        compile_local_program(sim; strategy=arm.strategy, packed=arm.packed, block_size)
    else
        compile_program(sim; strategy=arm.strategy, packed=arm.packed, block_size)
    end
    if _experiment_flag(arm, :regular)
        reason = _regular_reason(_regular_underlying(program).plan)
        return RegularGeneratedProgram(program, reason === :eligible, reason, 0, 0)
    end
    return program
end

measurement_phase(m) = (
    seconds=m.time,
    allocated_bytes=m.bytes,
    gc_seconds=m.gctime,
    compilation_seconds=hasproperty(m, :compile_time) ? m.compile_time : nothing,
    recompilation_seconds=hasproperty(m, :recompile_time) ? m.recompile_time : nothing,
)

"""A portable exact digest; ordering of internal dictionaries is not evidence."""
function portable_snapshot(sim)
    states = [
        (id=repr(object.id.value), fields=[
            (name=string(name), type=string(typeof(value)), value=repr(value))
            for (name, value) in pairs(PSE.final_state(sim, object.id))
        ])
        for object in PSE.model_objects(PSE.runtime_model(sim))
    ]
    sort!(states; by=x -> x.id)
    for state in states
        sort!(state.fields; by=x -> x.name)
    end
    history = [
        (key=repr(key), samples=repr(collect(stream)))
        for (key, stream) in pairs(PSE.outputs(sim))
    ]
    sort!(history; by=x -> x.key)
    return (step=PSE.current_step(sim), states, history)
end

snapshot_digest(sim) = bytes2hex(sha256(repr(portable_snapshot(sim))))

function sample_program(arm; nobjects=32, nmodels=4, steps=32,
    value_type=Float64, extras=0, environment_used=false, outputs=:none,
    block_size=4, retained_size=false)
    construction = @timed fixture_builder(;
        nobjects, nmodels, value_type, extras, environment_used,
    )
    preparation = @timed PSE.run!(construction.value; steps=0, outputs)
    sim = preparation.value
    lowering = if arm.strategy === :executor
        @timed nothing
    else
        @timed lower_experiment(sim, arm; block_size)
    end
    program = lowering.value
    execution = if arm.strategy === :executor
        @timed PSE.continue!(sim; steps)
    else
        @timed advance_program!(program; steps)
    end
    # Digest, size traversal and strategy inspection occur outside all timings.
    digest = snapshot_digest(sim)
    coverage = isnothing(program) ? (strategy=:executor,) : strategy_report(program)
    sizes = retained_size ? (
        simulation_bytes=Base.summarysize(sim),
        program_bytes=isnothing(program) ? 0 : Base.summarysize(program),
    ) : nothing
    phases = (construction=measurement_phase(construction),
        preparation=measurement_phase(preparation),
        lowering=measurement_phase(lowering), execution=measurement_phase(execution))
    complete_seconds = sum(p.seconds for p in values(phases))
    complete_allocated_bytes = sum(p.allocated_bytes for p in values(phases))
    return (; arm=arm.name, phases, complete_seconds, complete_allocated_bytes,
        digest, coverage, retained_size=sizes)
end

"""Small serial screening, with all arms warmed and alternating sample order."""
function screen_programs(; arms=SCREEN_ARMS, repetitions=3, kwargs...)
    repetitions > 0 || error("repetitions must be positive")
    warmups = [sample_program(arm; kwargs...) for arm in arms]
    expected = first(warmups).digest
    all(x -> x.digest == expected, warmups) || error("Warmup state/history mismatch")
    samples = NamedTuple[]
    for cycle in 1:repetitions
        order = isodd(cycle) ? arms : reverse(arms)
        for arm in order
            sample = sample_program(arm; kwargs...)
            sample.digest == expected || error("State/history mismatch for $(arm.name)")
            push!(samples, (; cycle, sample...))
        end
    end
    return (; config=(; kwargs...), repetitions, warmups, samples)
end

function summarize_screen(screen; baseline=:executor)
    baseline_samples = filter(x -> x.arm === baseline, screen.samples)
    names = unique(x.arm for x in screen.samples)
    return [begin
        samples = filter(x -> x.arm === name, screen.samples)
        ratios = [begin
            base = only(filter(x -> x.cycle == sample.cycle, baseline_samples))
            (execution=sample.phases.execution.seconds / base.phases.execution.seconds,
                complete=sample.complete_seconds / base.complete_seconds)
        end for sample in samples]
        (arm=name,
            execution_seconds=median(x.phases.execution.seconds for x in samples),
            complete_seconds=median(x.complete_seconds for x in samples),
            allocated_bytes=median(x.complete_allocated_bytes for x in samples),
            execution_allocated_bytes=median(x.phases.execution.allocated_bytes for x in samples),
            execution_ratio=median(x.execution for x in ratios),
            complete_ratio=median(x.complete for x in ratios),
            cycle_ratios=ratios,
            coverage=first(samples).coverage)
    end for name in names]
end
