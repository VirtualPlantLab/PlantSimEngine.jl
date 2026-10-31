# Direct-column experiment. The hot loop sees typed numerical columns and model
# payloads, rather than prebuilt Status/RefArray headers or execution targets.

struct SharedColumnModel{M}
    model::M
end
struct PerRowColumnModels{V}
    models::V
end
@inline _column_model_at(models::SharedColumnModel, row) = models.model
@inline _column_model_at(models::PerRowColumnModels, row) = @inbounds models.models[row]

struct ColumnKernel{Publish,M,C,E,O}
    models::M
    context::C
    environment_provider::E
    output_bindings::O
end

struct ColumnData{C,R}
    arrays::C
    recipe::R
    nrows::Int
end

struct ColumnExecutionRegion{K,D}
    first_entry::Int
    last_entry::Int
    kernels::K
    data::D
end

mutable struct ColumnGeneratedProgram{G}
    base::G
end

program_simulation(program::ColumnGeneratedProgram) = program_simulation(program.base)
strategy_report(program::ColumnGeneratedProgram) = strategy_report(program.base)

function _column_kernel(batch::ProgramDirectBatch)
    targets = batch.batch.targets
    isempty(targets) && throw(ArgumentError("Cannot compile an empty column kernel."))
    model = first(targets).model
    models = if all(target -> target.model === model, targets)
        SharedColumnModel(model)
    else
        PerRowColumnModels(_program_concrete_vector([target.model for target in targets]))
    end
    context = first(targets).context
    all(target -> typeof(target.context) === typeof(context), targets) || throw(ArgumentError(
        "Column kernels require homogeneous original context dispatch types.",
    ))
    # :local forbids context observation, so one original typed value preserves
    # run! dispatch without loading an execution-target header for each row.
    return ColumnKernel{batch.batch.output_publication.enabled,
        typeof(models),typeof(context),typeof(batch.batch.environment_provider),
        typeof(batch.output_bindings)}(models, context,
        batch.batch.environment_provider, batch.output_bindings)
end

function _column_data(store)
    store.cross_row_alias_count == 0 || throw(ArgumentError(
        "Direct-column loops require disjoint object rows.",
    ))
    source_rows = packed_statuses(store)
    isempty(source_rows) && throw(ArgumentError("Cannot compile empty column data."))
    names = propertynames(first(source_rows))
    recipe = if iszero(store.alias_count)
        LocalStateRecipe{names,ntuple(identity, length(names))}()
    else
        first_recipe = local_state_recipe(first(source_rows))
        all(row -> typeof(local_state_recipe(row)) === typeof(first_recipe), source_rows) ||
            throw(ArgumentError("Column rows require one within-row alias pattern."))
        first_recipe
    end
    arrays = map(column -> column.values, store.columns)
    return ColumnData(arrays, recipe, length(source_rows))
end

@inline _column_publish!(kernel::ColumnKernel{false}, local_status, row, step) = nothing
@inline function _column_publish!(kernel::ColumnKernel{true}, local_status, row, step)
    @inbounds _publish_local_outputs!(kernel.output_bindings[row], local_status, step)
    return nothing
end

@inline function _column_environment(kernel::ColumnKernel, simulation, step)
    context = kernel.context
    context isa PSE.RunContext && (context.time = float(step))
    # Only Nothing and RawGlobalModelEnvironment pass ordinary eligibility.
    # Their original sampling methods do not use the application argument.
    return PSE._model_execution_batch_environment(kernel.environment_provider,
        simulation.environment_bindings, nothing, step)
end

# All arrays, numerical model parameters and original context dispatch types are
# concrete here. The row Status and its RefArray cells are constructed locally;
# no execution target or stored row-header array is accessed inside this loop.
@inline @generated function _column_numerical_loop!(
    data::ColumnData{C,R}, kernels::K, environments::E, constants, step,
) where {C,R<:LocalStateRecipe,K<:Tuple,E<:Tuple}
    names, aliases = R.parameters
    references = [Symbol(:column_cell_, i) for i in eachindex(names)]
    loads = [:( $(references[i]) = Ref(getproperty(data.arrays,
        $(QuoteNode(names[i]))), row)) for i in eachindex(names) if aliases[i] == i]
    cells = Expr(:tuple, (references[aliases[i]] for i in eachindex(names))...)
    constructor = :(PSE.Status(NamedTuple{$(QuoteNode(names))}($cells)))
    calls = Expr[]
    for i in 1:fieldcount(K)
        push!(calls, quote
            kernel = getfield(kernels, $i)
            model = _column_model_at(kernel.models, row)
            Base.@inline PSE.run!(model, local_status,
                getfield(environments, $i), constants, kernel.context)
            _column_publish!(kernel, local_status, row, step)
        end)
    end
    return quote
        for row in 1:data.nrows
            $(loads...)
            local_status = $constructor
            $(calls...)
        end
        nothing
    end
end

@inline @generated function _program_run_column_region!(
    node::ColumnExecutionRegion{K,D}, simulation, step,
) where {K<:Tuple,D}
    environments = Expr(:tuple,
        [:( _column_environment(getfield(node.kernels, $i), simulation, step))
            for i in 1:fieldcount(K)]...)
    return quote
        environment_rows = $environments
        Base.@inline _column_numerical_loop!(node.data, node.kernels,
            environment_rows, simulation.constants, step)
        nothing
    end
end

@noinline function _program_run_node!(node::ColumnExecutionRegion, simulation, step)
    _program_run_column_region!(node, simulation, step)
    return nothing
end
@inline function _program_run_application!(node::ColumnExecutionRegion, simulation, step)
    Base.@inline _program_run_column_region!(node, simulation, step)
    return nothing
end

function _compile_column_plan(base)
    plan = base.plan
    store = plan.packed_store
    nodes = Any[]
    converted_regions = 0
    converted_applications = 0
    shared_models = 0
    row_models = 0
    selected = !isnothing(store) && plan.fixed_local
    reason = selected ? :eligible : :requires_complete_packable_local_scene
    data = nothing
    if selected
        try
            data = _column_data(store)
        catch error_
            error_ isa ArgumentError || rethrow()
            selected = false
            reason = :unsupported_column_alias_schema
        end
    end
    if selected
        for node in plan.nodes
            if node isa ProgramFusedRegion
                batches = node.batches
            elseif node isa ProgramApplication && node.direct && length(node.batches) == 1
                batches = node.batches
            elseif node isa ProgramApplication && isempty(node.batches)
                push!(nodes, node)
                continue
            else
                selected = false
                reason = :unsupported_execution_region
                break
            end
            kernels = map(_column_kernel, batches)
            push!(nodes, ColumnExecutionRegion(node.first_entry, node.last_entry, kernels, data))
            converted_regions += 1
            converted_applications += length(kernels)
            shared_models += count(kernel -> kernel.models isa SharedColumnModel, kernels)
            row_models += count(kernel -> kernel.models isa PerRowColumnModels, kernels)
        end
    end
    if !selected
        nodes = Any[plan.nodes...]
        converted_regions = converted_applications = shared_models = row_models = 0
    end
    report = merge(plan.report, (
        column_requested=true,
        column_selected=selected,
        column_reason=reason,
        column_regions=converted_regions,
        column_applications=converted_applications,
        column_shared_model_payloads=shared_models,
        column_per_row_model_payloads=row_models,
        column_row_headers=:constructed_inside_numeric_loop,
        column_targets_in_numeric_loop=false,
        column_context=:original_typed_first_value_per_kernel,
        column_canonical_refs_retained=true,
    ))
    return ProgramPlan(Tuple(nodes), plan.schedule, store,
        plan.runtime_revision, plan.fixed_local, report)
end

"""
    compile_column_program(simulation; strategy=:typed, block_size=4)

Run original kernels over locally constructed real Status/RefArray row views of
typed numerical columns. Shared model payloads are hoisted after identity proof;
otherwise a concrete per-row model vector preserves parameter differences.
Unsupported scenes retain ordinary generated execution with explicit coverage.
"""
function compile_column_program(simulation; strategy::Symbol=:typed, block_size::Int=4)
    base = compile_program(simulation; strategy, packed=true, block_size)
    base.plan = _compile_column_plan(base)
    return ColumnGeneratedProgram(base)
end

function _column_refresh!(program::ColumnGeneratedProgram)
    base = program.base
    _program_ensure_plan!(base)
    if !hasproperty(base.plan.report, :column_requested)
        base.plan = _compile_column_plan(base)
    end
    return base.plan
end

function advance_program!(program::ColumnGeneratedProgram; steps::Integer=1)
    steps >= 0 || throw(ArgumentError("steps must be non-negative"))
    base = program.base
    plan = _column_refresh!(program)
    if plan.fixed_local
        return advance_program!(base; steps)
    end
    for _ in 1:steps
        _column_refresh!(program)
        advance_program!(base; steps=1)
    end
    _column_refresh!(program)
    return base.simulation
end

if isdefined(@__MODULE__, :RegularGeneratedProgram)
    _regular_underlying(program::ColumnGeneratedProgram) = program.base
    _regular_refresh!(program::ColumnGeneratedProgram) = _column_refresh!(program)

    """Combine direct columns with the independent always-due clock lowering."""
    function compile_regular_column_program(simulation; strategy::Symbol=:typed,
        block_size::Int=4)
        base = compile_column_program(simulation; strategy, block_size)
        reason = _regular_reason(base.base.plan)
        return RegularGeneratedProgram(base, reason === :eligible, reason, 0, 0)
    end
end
