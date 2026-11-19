# Diagnostic output only; no scientific/model argument enters this logger.
function _xpalm_preparation_phase!(phase::Symbol; pass::Symbol=:none,
    day::Int=0, application::Symbol=:none)
    path = get(ENV, "PSE_XPALM_PREPARATION_LOG", "")
    isempty(path) && return nothing
    open(path, "a") do io
        println(io, time_ns(), '\t', getpid(), '\t', phase, '\t', pass, '\t', day, '\t', application)
        flush(io)
    end
    return nothing
end

# Private build-time observation of this actual XPalm trajectory only.
# No materialization, evaluation, sampling, or model hook is invoked by observers.
function _new_xpalm_witness(simulation)
    ids = Symbol[application.id for application in simulation.compiled.applications]
    return (batches=Dict(id => DataType[] for id in ids),
        inputs=DataType[], views=Dict(id => DataType[] for id in ids),
        environment=PSE._collecting_environment_binding_schema())
end

function _remember_xpalm_type!(types, value)
    T = typeof(value)
    T in types || push!(types, T)
    return nothing
end

function _observe_xpalm_context!(witness, context, seen)
    context isa PSE.RunContext || return nothing
    for targets in context.calls
        haskey(seen, targets) && continue
        seen[targets] = nothing
        cached = PSE._cached_call_execution_batches(targets)
        isnothing(cached) && continue
        for batch in cached
            _observe_xpalm_batch!(witness, batch, seen)
        end
    end
    return nothing
end

function _observe_xpalm_batch!(witness, batch, seen)
    batch isa PSE.CompiledExecutionBatch || error("Unexpected real XPalm batch class.")
    _remember_xpalm_type!(witness.batches[batch.application.id], batch)
    # Do not traverse cached row views: their membership can be stale after a
    # real removal. Current contexts are visited through the canonical store.
    return nothing
end

function _observe_xpalm!(witness, simulation)
    for binding in simulation.compiled.input_bindings
        _remember_xpalm_type!(witness.inputs, binding)
    end
    for (key, view) in simulation.compiled.status_views_by_target
        _remember_xpalm_type!(witness.views[first(key)], view)
    end
    for plan in simulation.environment_bindings.application_plans
        PSE._remember_environment_type!(witness.environment.plans, typeof(plan))
    end
    for binding in simulation.environment_bindings.bindings
        PSE._remember_environment_type!(witness.environment.bindings, typeof(binding))
    end
    seen = IdDict{Any,Nothing}()
    for group in simulation.execution_plan.groups, batch in group.batches
        _observe_xpalm_batch!(witness, batch, seen)
    end
    # Manual and private call owners also live in this canonical store. Read
    # their already cached batches even when they are absent from top-level groups.
    for location in values(simulation.execution_plan.cohorts.locations)
        target = PSE._execution_cohort_target(location)
        _observe_xpalm_context!(witness, target.context, seen)
    end
    return nothing
end

function _run_xpalm_witness!(state, witness, pass)
    _xpalm_preparation_phase!(:trajectory_body_entry; pass)
    rows = Any[]
    _xpalm_preparation_phase!(:before_observe_T0; pass)
    _observe_xpalm!(witness, state.simulation)
    _xpalm_preparation_phase!(:after_observe_T0; pass)
    for day in eachindex(state.date_labels)
        (day == 1 || day % 365 == 0 || day == length(state.date_labels)) && _xpalm_preparation_phase!(:before_step; pass, day)
        PSE.step!(state.simulation)
        (day == 1 || day % 365 == 0 || day == length(state.date_labels)) && _xpalm_preparation_phase!(:after_step; pass, day)
        (day == 1 || day % 365 == 0 || day == length(state.date_labels)) && _xpalm_preparation_phase!(:before_observe_step; pass, day)
        _observe_xpalm!(witness, state.simulation)
        (day == 1 || day % 365 == 0 || day == length(state.date_labels)) && _xpalm_preparation_phase!(:after_observe_step; pass, day)
        (day == 1 || day % 365 == 0 || day == length(state.date_labels)) && _xpalm_preparation_phase!(:before_daily_snapshot; pass, day)
        push!(rows, daily_snapshot(state))
        (day == 1 || day % 365 == 0 || day == length(state.date_labels)) && _xpalm_preparation_phase!(:after_daily_snapshot; pass, day)
        (day == 1 || day % 365 == 0 || day == length(state.date_labels)) &&
            @info "Real XPalm witness progress" pass day
    end
    return rows
end

function _xpalm_finite_owners(witness, application_ids)
    missing = Symbol[id for id in application_ids if isempty(witness.views[id])]
    isempty(missing) || error("No real status-view witness for declared XPalm applications: ", missing)
    all(T -> isconcretetype(T) && T <: PSE.CompiledModelInputBinding, witness.inputs) ||
        error("XPalm input evidence is not concrete.")
    input_prototype = Vector{Union{witness.inputs...}}()
    vectors = Any[]
    for id in application_ids
        types = witness.views[id]
        all(T -> isconcretetype(T) && T <: PSE.CompiledModelStatusView, types) ||
            error("XPalm status-view evidence is not concrete for ", id)
        push!(vectors, Vector{Union{types...}}())
    end
    view_schema = PSE.CompiledMetadataTable(NamedTuple{Tuple(application_ids)}(Tuple(vectors)))
    environment_schema = PSE._freeze_environment_binding_schema(witness.environment)
    return (; input_prototype, view_schema, environment_schema)
end

function _xpalm_prepared_batch_schemas(compiled, witness)
    order = PSE._stable_topological_application_order(compiled.applications,
        compiled.scenario_plan.call_owners)
    missing = Symbol[id for id in order if isempty(witness.batches[id])]
    isempty(missing) || error("No real execution-batch witness for declared XPalm applications: ", missing)
    lowered = Dict{Symbol,Vector{DataType}}()
    schemas = Dict{Symbol,Any}()
    for id in order
        _xpalm_preparation_phase!(:before_application_lowering; application=id)
        @info "Real XPalm batch lowering" phase=:before_application application=id
        plans = PSE._with_metadata_entry(identity,
            compiled.scenario_plan.call_plans_by_application, id)
        lowered[id] = DataType[]
        for B in witness.batches[id]
            Context = fieldtype(eltype(fieldtype(B, :targets)), :context)
            calls = fieldtype(Context, :calls)
            names = Symbol[]
            call_schemas = Any[]
            for CT in fieldtypes(calls)
                Binding = fieldtype(CT, :binding)
                Plan = fieldtype(Binding, :plan)
                plan = only(plan for plan in plans if typeof(plan) === Plan)
                name = PSE._prepared_call_name(Binding)
                family = DataType[]
                for callee in plan.potential_callee_application_ids
                    haskey(lowered, callee) || error("XPalm call DAG is not bottom-up for ", id, " -> ", callee)
                    for T in lowered[callee]
                        T in family || push!(family, T)
                    end
                end
                isempty(family) && error("No actual future callee batch for XPalm call ", id, ".", name)
                push!(names, name)
                push!(call_schemas, PSE.PreparedExecutionBatchSchema{Vector{Union{family...}}}())
            end
            call_schema = NamedTuple{Tuple(names)}(Tuple(call_schemas))
            _xpalm_preparation_phase!(:before_batch_lowering; application=id)
            @info "Real XPalm batch lowering" phase=:before_batch application=id
            T = PSE._execution_batch_type_with_call_schemas(B, call_schema)
            _xpalm_preparation_phase!(:after_batch_lowering; application=id)
            @info "Real XPalm batch lowering" phase=:after_batch application=id
            T in lowered[id] || push!(lowered[id], T)
        end
        family = lowered[id]
        schemas[id] = PSE.PreparedExecutionBatchSchema{Vector{Union{family...}}}()
        _xpalm_preparation_phase!(:after_application_lowering; application=id)
        @info "Real XPalm batch lowering" phase=:after_application application=id family_count=length(family)
    end
    return NamedTuple{Tuple(order)}(Tuple(schemas[id] for id in order))
end

# Public observations of the 17 official retained quantities at real T0.
function _xpalm_requested_initial_values(state)
    fields = (Scene=:scene, Plant=:plant, Soil=:soil)
    result = Dict{Tuple{Symbol,Symbol},Any}()
    for (scale, variables) in OUTPUT_VARIABLES
        status = PSE.model_status(state.simulation, getproperty(state.object_ids, getproperty(fields, scale)))
        for variable in variables
            result[(scale, variable)] = getproperty(status, variable)
        end
    end
    return result
end

function _xpalm_requested_initial_references(state)
    fields = (Scene=:scene, Plant=:plant, Soil=:soil)
    result = Dict{Tuple{Symbol,Symbol},Any}()
    for (scale, variables) in OUTPUT_VARIABLES
        status = PSE.model_status(state.simulation, getproperty(state.object_ids, getproperty(fields, scale)))
        for variable in variables
            result[(scale, variable)] = PSE.refvalue(status, variable)
        end
    end
    return result
end

function prepare_witnessed_application()
    @info "Real XPalm finite preparation" phase=:before_ordinary_witness
    _xpalm_preparation_phase!(:before_ordinary_T0)
    ordinary = prepare_application()
    _xpalm_preparation_phase!(:after_ordinary_T0)
    _xpalm_preparation_phase!(:before_initial_values)
    initial_values = _xpalm_requested_initial_values(ordinary)
    _xpalm_preparation_phase!(:after_initial_values)
    _xpalm_preparation_phase!(:before_new_observer)
    first_witness = _new_xpalm_witness(ordinary.simulation)
    _xpalm_preparation_phase!(:after_new_observer)
    _xpalm_preparation_phase!(:before_ordinary_trajectory)
    first_rows = _run_xpalm_witness!(ordinary, first_witness, :ordinary)
    _xpalm_preparation_phase!(:after_ordinary_trajectory)
    @info "Real XPalm finite preparation" phase=:after_ordinary_witness
    application_ids = Symbol[application.id for application in ordinary.simulation.compiled.applications]
    _xpalm_preparation_phase!(:before_finite_owners)
    owners = _xpalm_finite_owners(first_witness, application_ids)
    _xpalm_preparation_phase!(:after_finite_owners)
    @info "Real XPalm finite preparation" phase=:before_finite_owner_witness
    _xpalm_preparation_phase!(:before_finite_T0)
    finite = prepare_application(; owners)
    _xpalm_preparation_phase!(:after_finite_T0)
    second_witness = _new_xpalm_witness(finite.simulation)
    _xpalm_preparation_phase!(:before_finite_trajectory)
    second_rows = _run_xpalm_witness!(finite, second_witness, :finite_owners)
    _xpalm_preparation_phase!(:after_finite_trajectory)
    isequal(first_rows, second_rows) || error("Real XPalm daily values changed under finite metadata owners.")
    @info "Real XPalm finite preparation" phase=:after_finite_owner_witness
    _xpalm_preparation_phase!(:before_schema_lowering)
    schemas = _xpalm_prepared_batch_schemas(finite.simulation.compiled, second_witness)
    _xpalm_preparation_phase!(:after_schema_lowering)
    @info "Real XPalm finite preparation" phase=:before_fresh_T0
    _xpalm_preparation_phase!(:before_fresh_T0)
    fresh = prepare_application(; owners)
    _xpalm_preparation_phase!(:after_fresh_T0)
    isequal(_xpalm_requested_initial_values(fresh), initial_values) || error("Fresh finite XPalm T0 values changed.")
    initial_references = _xpalm_requested_initial_references(fresh)
    _xpalm_preparation_phase!(:before_close_T0)
    simulation = PSE._prepare_execution_batch_schemas(fresh.simulation, schemas)
    _xpalm_preparation_phase!(:after_close_T0)
    prepared_state = (; fresh..., simulation)
    isequal(_xpalm_requested_initial_values(prepared_state), initial_values) || error("Closing XPalm batches changed T0 values.")
    prepared_references = _xpalm_requested_initial_references(prepared_state)
    all(prepared_references[key] === reference for (key, reference) in initial_references) ||
        error("Closing XPalm batches replaced a canonical requested Ref.")
    PSE.current_step(simulation) == 0 || error("XPalm finite preparation advanced fresh T0.")
    all(isempty, values(PSE.collect_outputs(simulation; sink=nothing))) || error("XPalm T0 has output history.")
    @info "Real XPalm finite preparation" phase=:after_fresh_T0
    return prepared_state
end
