# Independent-trajectory experiment: one object's complete local model stack
# advances through a time span before the next object. The numerical method
# bodies are unchanged; this transforms only proven-independent loop ordering.

struct TemporalTrajectoryPlan{K,D}
    kernels::K
    data::D
end

mutable struct TemporalGeneratedProgram{B}
    base::B
    temporal_plan::Any
    selected::Bool
    reason::Symbol
    temporal_steps::Int
    fallback_steps::Int
end

program_simulation(program::TemporalGeneratedProgram) = program_simulation(program.base)

function _temporal_forcing_reason(provider)
    isnothing(provider) && return :eligible
    provider isa PSE.RawGlobalModelEnvironment || return :effectful_environment_provider
    source = provider.sampled_environment
    source isa NamedTuple && isbitstype(typeof(source)) && return :eligible
    source isa Vector && eltype(source) <: NamedTuple && isbitstype(eltype(source)) &&
        return :eligible
    if source isa PSE.PreparedGlobalEnvironmentRows
        rows = source.rows
        rows isa Vector && eltype(rows) <: NamedTuple && isbitstype(eltype(rows)) &&
            return :eligible
    end
    return :forcing_requires_pure_indexed_values
end

function _temporal_plan(column_program::ColumnGeneratedProgram)
    plan = column_program.base.plan
    reason = _regular_reason(plan)
    reason === :eligible || return (nothing, reason)
    hasproperty(plan.report, :column_selected) && plan.report.column_selected ||
        return (nothing, :requires_direct_column_scene)
    kernels = Any[]
    data = nothing
    for node in plan.nodes
        if node isa ColumnExecutionRegion
            if isnothing(data)
                data = node.data
            else
                node.data.nrows == data.nrows && node.data.arrays === data.arrays &&
                    typeof(node.data.recipe) === typeof(data.recipe) ||
                    return (nothing, :different_column_memberships)
            end
            for kernel in node.kernels
                forcing_reason = _temporal_forcing_reason(kernel.environment_provider)
                forcing_reason === :eligible || return (nothing, forcing_reason)
                push!(kernels, kernel)
            end
        elseif node isa ProgramApplication && isempty(node.batches)
            continue
        else
            return (nothing, :ordered_region_boundary)
        end
    end
    isempty(kernels) && return (nothing, :empty_local_stack)
    return TemporalTrajectoryPlan(Tuple(kernels), data), :eligible
end

function strategy_report(program::TemporalGeneratedProgram)
    plan = program.temporal_plan
    return merge(strategy_report(program.base), (
        temporal_requested=true,
        temporal_selected=program.selected,
        temporal_reason=program.reason,
        temporal_steps=program.temporal_steps,
        temporal_fallback_steps=program.fallback_steps,
        temporal_loop_order=:object_then_time_then_entire_model_stack,
        temporal_local_state=:one_refvalue_status_per_object_per_advance,
        temporal_kernels=isnothing(plan) ? 0 : length(plan.kernels),
        temporal_forcing=:pure_values_frozen_within_advance,
    ))
end

"""
    compile_temporal_program(simulation; prepared=false)

Prototype complete independent object trajectories. Eligibility additionally
requires an always-due total/local scene, one column membership, and forcing
whose sampling is a pure value lookup. NamedTuple scalar forcing and builtin
Vector{<:NamedTuple} isbits rows (raw or prepared) must remain unchanged during each advance;
mutations between advances are read freshly. Arbitrary providers and all
coupled/effectful scenes retain the regular-column/generated feature paths.
"""
function compile_temporal_program(simulation; prepared::Bool=false)
    column_program = if prepared
        base = compile_prepared_program(simulation; strategy=:monolith, packed=true)
        base.plan = _compile_column_plan(base)
        ColumnGeneratedProgram(base)
    else
        compile_column_program(simulation; strategy=:monolith)
    end
    regular_reason = _regular_reason(column_program.base.plan)
    regular = RegularGeneratedProgram(column_program, regular_reason === :eligible,
        regular_reason, 0, 0)
    trajectory, reason = _temporal_plan(column_program)
    return TemporalGeneratedProgram(regular, trajectory, reason === :eligible, reason, 0, 0)
end

@inline function _temporal_environment(kernel::ColumnKernel, step)
    # Eligibility excludes providers that inspect bindings or application state.
    # The local effect promise forbids observing context. Updating its unused
    # time field once at the advance boundary avoids a store per kernel/row/tick.
    return PSE._model_execution_batch_environment(kernel.environment_provider,
        nothing, nothing, step)
end

function _temporal_validate_forcing_span!(kernels, final_step)
    for kernel in kernels
        provider = kernel.environment_provider
        isnothing(provider) && continue
        source = provider.sampled_environment
        if source isa Vector
            final_step <= length(source) || throw(ArgumentError(
                "Temporal trajectory span exceeds raw forcing rows.",
            ))
        elseif source isa PSE.PreparedGlobalEnvironmentRows
            final_step <= length(source.rows) || throw(ArgumentError(
                "Temporal trajectory span exceeds prepared forcing rows.",
            ))
        end
    end
    return nothing
end

# Keep the outer boundary's cleanup handler out of this numerical function. The
# effect promise explicitly rules out fallible scientific kernels in this path.
# Fresh local cells are created once per object, not once per object/timestep.
@noinline @generated function _temporal_numerical_loop!(
    data::ColumnData{C,R}, kernels::K, constants, first_step, steps,
) where {C,R<:LocalStateRecipe,K<:Tuple}
    names, aliases = R.parameters
    cells = [Symbol(:trajectory_cell_, i) for i in eachindex(names)]
    loads = [:( $(cells[i]) = Ref(@inbounds getproperty(data.arrays,
        $(QuoteNode(names[i])))[row])) for i in eachindex(names) if aliases[i] == i]
    references = Expr(:tuple, (cells[aliases[i]] for i in eachindex(names))...)
    constructor = :(PSE.Status(NamedTuple{$(QuoteNode(names))}($references)))
    stores = [:(@inbounds getproperty(data.arrays, $(QuoteNode(names[i])))[row] =
        getproperty(local_status, $(QuoteNode(names[i]))))
        for i in eachindex(names) if aliases[i] == i]
    model_names = [Symbol(:trajectory_model_, i) for i in 1:fieldcount(K)]
    model_loads = [:( $(model_names[i]) = _column_model_at(
        getfield(kernels, $i).models, row)) for i in 1:fieldcount(K)]
    calls = [quote
        kernel = getfield(kernels, $i)
        environment = _temporal_environment(kernel, step)
        Base.@inline PSE.run!($(model_names[i]), local_status, environment,
            constants, kernel.context)
        _column_publish!(kernel, local_status, row, step)
    end for i in 1:fieldcount(K)]
    return quote
        final_step = first_step + steps - 1
        for row in 1:data.nrows
            $(loads...)
            local_status = $constructor
            $(model_loads...)
            for step in first_step:final_step
                $(calls...)
            end
            $(stores...)
        end
        nothing
    end
end

function advance_program!(program::TemporalGeneratedProgram; steps::Integer=1)
    steps >= 0 || throw(ArgumentError("steps must be non-negative"))
    regular = program.base
    column = regular.base
    base = column.base
    plan = _column_refresh!(column)
    trajectory, reason = _temporal_plan(column)
    program.temporal_plan = trajectory
    program.selected = reason === :eligible
    program.reason = reason
    if !program.selected
        program.fallback_steps += steps
        return advance_program!(regular; steps)
    end
    simulation = base.simulation
    simulation.execution_plan.schedule.last_step == simulation.current_step || error(
        "Temporal program expected an aligned continuation clock.",
    )
    final_step = simulation.current_step + steps
    _temporal_validate_forcing_span!(trajectory.kernels, final_step)
    isnothing(plan.packed_store) || pull_packed!(plan.packed_store)
    empty!(simulation.environment_bindings.sample_cache)
    previous_step = simulation.current_step
    try
        _temporal_numerical_loop!(trajectory.data, trajectory.kernels,
            simulation.constants, previous_step + 1, steps)
        simulation.compiled.execution_generation += UInt64(steps)
        simulation.current_step = final_step
        for kernel in trajectory.kernels
            context = kernel.context
            context isa PSE.RunContext && (context.time = float(final_step))
        end
        program.temporal_steps += steps
        regular.selected = true
        regular.reason = :eligible
        regular.regular_steps += steps
    finally
        isnothing(plan.packed_store) || push_packed!(plan.packed_store)
        empty!(simulation.environment_bindings.sample_cache)
        _regular_restore_schedule!(simulation, plan)
    end
    PSE._compiled_source_finalize!(simulation)
    return simulation
end
