# Explicit preparation contracts live at the application/call owner. They are
# type-only metadata, never a catalogue in the scene or runtime storage.
abstract type ExecutionBatchSchema end
struct OpenExecutionBatchSchema <: ExecutionBatchSchema end

function _prepared_execution_batch_types(::Type{BT}) where {BT}
    isconcretetype(BT) || throw(ArgumentError("Prepared execution batches need a concrete finite container type."))
    batches = if BT <: Vector
        Tuple(Base.uniontypes(eltype(BT)))
    elseif BT <: Tuple
        fieldtypes(BT)
    else
        throw(ArgumentError("Prepared execution batches require Vector{B}, Vector{Union{B...}} or a fixed Tuple."))
    end
    isempty(batches) && throw(ArgumentError("An empty batch family needs explicit future batch types."))
    for B in batches
        isconcretetype(B) && B <: CompiledExecutionBatch ||
            throw(ArgumentError("Prepared batch families must be concrete canonical execution batches."))
        Rows = fieldtype(B, :targets)
        Rows <: ExecutionCohortRows && isconcretetype(Rows) ||
            throw(ArgumentError("Prepared batches must use concrete canonical cohort rows."))
        Target = eltype(Rows)
        isconcretetype(Target) && Target <: CompiledExecutionTarget ||
            throw(ArgumentError("Prepared rows require an explicit concrete execution-target type."))
        Context = fieldtype(Target, :context)
        isconcretetype(Context) && Context <: RunContext ||
            throw(ArgumentError("Prepared execution targets require a real concrete RunContext schema."))
        fieldtype(B, :application) === fieldtype(Context, :application) ||
            throw(ArgumentError("Prepared batch and context application schemas differ."))
        for name in (:object_id, :bound_inputs, :output_targets)
            fieldtype(Target, name) === fieldtype(Context, name) ||
                throw(ArgumentError("Prepared target and context fields disagree."))
        end
        _validate_prepared_context_calls(fieldtype(Context, :calls))
    end
    return batches
end

struct PreparedExecutionBatchSchema{BT} <: ExecutionBatchSchema
    function PreparedExecutionBatchSchema{BT}() where {BT}
        _prepared_execution_batch_types(BT)
        return new{BT}()
    end
end

abstract type ContextCallSchema end
struct OpenContextCallSchema <: ContextCallSchema end
struct PreparedContextCallSchema{C<:Tuple} <: ContextCallSchema
    PreparedContextCallSchema{C}() where {C<:Tuple} = new{C}()
end

_prepared_call_mode(::Type{<:CompiledModelCallBinding{P}}) where {P} = _prepared_call_plan_mode(P)
_prepared_call_plan_mode(::Type{<:CompiledModelCallPlan{NAME,MODE}}) where {NAME,MODE} = MODE

function _validate_prepared_context_calls(::Type{C}) where {C<:Tuple}
    isconcretetype(C) || throw(ArgumentError("Prepared context calls require a concrete finite tuple."))
    for CT in fieldtypes(C)
        CT <: CallTargets && isconcretetype(CT) || throw(ArgumentError("A prepared context contains a non-concrete CallTargets schema."))
        S = fieldtype(CT, :batch_schema)
        S <: PreparedExecutionBatchSchema || throw(ArgumentError("Every prepared call needs an explicit current/future batch schema."))
        BT = only(S.parameters)
        _prepared_execution_batch_types(BT)
        actual = fieldtype(CT, :execution_batches)
        expected = _prepared_call_mode(fieldtype(CT, :binding)) === :initializer ? Tuple{} : BT
        actual === expected || throw(ArgumentError("Prepared call container and explicit batch schema disagree."))
    end
    return nothing
end

@generated function _execution_cohort_schema(::PreparedExecutionBatchSchema{BT}) where {BT}
    targets = unique(eltype(fieldtype(B, :targets)) for B in _prepared_execution_batch_types(BT))
    return :(_closed_execution_cohort_schema($(Tuple{targets...})))
end

_execution_batch_buffer(::OpenExecutionBatchSchema) = AbstractExecutionBatch[]
@generated function _execution_batch_buffer(::PreparedExecutionBatchSchema{BT}) where {BT}
    batches = _prepared_execution_batch_types(BT)
    return :(Vector{$(Union{batches...})}())
end

_finish_execution_batches(::OpenExecutionBatchSchema, batches) = Tuple(batches)
@generated function _finish_execution_batches(::PreparedExecutionBatchSchema{BT}, batches) where {BT}
    if BT <: Vector
        return :(batches::$BT)
    end
    entries = [gensym(:batch) for _ in 1:fieldcount(BT)]
    checks = Any[]
    for (index, B) in enumerate(fieldtypes(BT))
        push!(checks, :($(entries[index]) = batches[$index]))
        push!(checks, :($(entries[index]) isa $B || throw(ArgumentError("A batch is outside its prepared ordered schema."))))
    end
    result = Expr(:tuple, [:($(entries[index])::$(fieldtype(BT, index))) for index in eachindex(entries)]...)
    return quote
        length(batches) == $(fieldcount(BT)) || throw(ArgumentError("Prepared ordered batch count changed."))
        $(checks...)
        return $result
    end
end

@inline _with_execution_batch(f, ::OpenExecutionBatchSchema, batch) = f(batch)
@generated function _with_execution_batch(f, ::PreparedExecutionBatchSchema{BT}, batch) where {BT}
    branches = [:(batch isa $B && return f(batch::$B)) for B in _prepared_execution_batch_types(BT)]
    return quote
        $(branches...)
        throw(ArgumentError("The execution batch is outside its prepared application schema."))
    end
end

@inline _with_new_execution_batch(f, ::OpenExecutionBatchSchema, application, rows, provider, publication) =
    f(CompiledExecutionBatch(application, rows, provider, publication))
@generated function _with_new_execution_batch(f, ::PreparedExecutionBatchSchema{BT}, application, rows, provider, publication) where {BT}
    branches = Expr[]
    for B in _prepared_execution_batch_types(BT)
        A, R, P, O = (fieldtype(B, name) for name in (:application, :targets, :environment_provider, :output_publication))
        push!(branches, quote
            if application isa $A && rows isa $R && provider isa $P && publication isa $O
                return f(CompiledExecutionBatch(application::$A, rows::$R, provider::$P, publication::$O))
            end
        end)
    end
    return quote
        $(branches...)
        throw(ArgumentError("The real batch fields do not match an admitted execution schema."))
    end
end

@inline _context_call_schema(::Nothing) = OpenContextCallSchema()
@generated function _context_call_schema(context::RunContext{CS,A,C}) where {CS,A,C}
    closed = any(fieldtype(CT, :batch_schema) <: PreparedExecutionBatchSchema for CT in fieldtypes(C))
    return closed ? :(PreparedContextCallSchema{$C}()) : :(OpenContextCallSchema())
end

@inline _with_execution_target_type(f, ::OpenExecutionCohortSchema, application, fields, owners) = f(nothing, application, fields, owners, OpenContextCallSchema())
@generated function _with_execution_target_type(f, ::ClosedExecutionCohortSchema{T}, application, fields, owners) where {T}
    branches = Expr[]
    names = (:object_id, :model, :status_view, :bound_inputs,
        :output_targets, :call_bindings, :environment_binding)
    for Target in fieldtypes(T)
        Target <: CompiledExecutionTarget || error("Closed target factory needs canonical execution-target schemas.")
        Context = fieldtype(Target, :context)
        Context <: RunContext && isconcretetype(Context) || error("A prepared target requires a real concrete context.")
        Calls = fieldtype(Context, :calls)
        closed_calls = any(fieldtype(CT,:batch_schema) <: PreparedExecutionBatchSchema for CT in fieldtypes(Calls))
        closed_calls && _validate_prepared_context_calls(Calls)
        CallSchema = closed_calls ? PreparedContextCallSchema{Calls} : OpenContextCallSchema
        checks = Expr[:(application isa $(fieldtype(Context, :application)))]
        for name in names
            push!(checks, :(getproperty(fields, $(QuoteNode(name))) isa $(fieldtype(Target, name))))
        end
        for name in (:compiled, :temporal_streams, :output_retention, :constants, :environment)
            push!(checks, :(getproperty(owners, $(QuoteNode(name))) isa $(fieldtype(Context, name))))
        end
        condition = foldl((a,b) -> :($a && $b), checks)
        values = Expr(:tuple, [:(getproperty(fields, $(QuoteNode(name)))::$(fieldtype(Target,name))) for name in names]...)
        owner_names = (:compiled, :temporal_streams, :output_retention, :constants, :environment)
        owner_values = Expr(:tuple, [:(getproperty(owners, $(QuoteNode(name)))::$(fieldtype(Context,name))) for name in owner_names]...)
        A = fieldtype(Context, :application)
        push!(branches, quote
            if $condition
                actual_fields = NamedTuple{$(QuoteNode(names))}($values)
                actual_owners = NamedTuple{$(QuoteNode(owner_names))}($owner_values)
                return f($Target, application::$A, actual_fields, actual_owners,
                    $CallSchema())
            end
        end)
    end
    return quote
        $(branches...)
        throw(ArgumentError("The real target fields are outside the prepared execution schema."))
    end
end

# Validate the type-only application tree in the already validated call DAG's
# bottom-up order. call_owners already maps callee -> callers; reuse the one
# canonical topological ordering operation, without discovering another graph.
function _prepared_application_schema_order(compiled::CompiledCompositeModel, schemas::NamedTuple)
    order = _stable_topological_application_order(compiled.applications,
        compiled.scenario_plan.call_owners)
    for application_id in order
        haskey(schemas, application_id) || throw(ArgumentError("An application lacks an explicit execution batch schema."))
        schema = getproperty(schemas, application_id)
        schema isa PreparedExecutionBatchSchema || throw(ArgumentError("Prepared applications require explicit batch schemas."))
        application = compiled.applications_by_id[application_id]
        for B in _prepared_execution_batch_types(only(typeof(schema).parameters))
            fieldtype(B, :application) === typeof(application) || throw(ArgumentError("Prepared application and batch types disagree."))
        end
    end
    return Tuple(order)
end

Base.@nospecializeinfer function _call_execution_batches_for_schema(
    ::OpenExecutionBatchSchema, compiled, environment_bindings, binding,
    temporal_streams, output_retention, constants, tracks_full_membership,
)
    @nospecialize compiled environment_bindings binding
    if _compiled_call_mode(binding) === :initializer
        return ()
    elseif binding.multiplicity === :many
        return LazyCallExecutionBatches()
    end
    return _compiled_call_execution_batches(compiled, environment_bindings,
        binding, temporal_streams, output_retention, constants)
end

function _call_execution_batches_for_schema(schema::PreparedExecutionBatchSchema,
    compiled, environment_bindings, binding, temporal_streams,
    output_retention, constants, tracks_full_membership,
)
    _compiled_call_mode(binding) === :initializer && return ()
    if tracks_full_membership
        _observe_compiled_call_membership!(compiled, binding;
            resolve_current=!bindings_dirty(compiled.model))
    end
    return _compiled_call_execution_batches(compiled, environment_bindings,
        binding, temporal_streams, output_retention, constants;
        cohort_schema=_execution_cohort_schema(schema), batch_schema=schema)
end

@inline _assemble_runtime_call_targets(::OpenContextCallSchema, compiled,
    environment_bindings, ::Tuple{}, args...) = ()

Base.@nospecializeinfer function _assemble_runtime_call_targets(
    ::OpenContextCallSchema, compiled, environment_bindings, bindings::Tuple,
    temporal_streams, output_retention, time, constants, publication_allowed,
    environment,
)
    @nospecialize compiled environment_bindings bindings
    targets = CallTargets[]
    for binding in bindings
        push!(targets, CallTargets(compiled, environment_bindings, binding,
            temporal_streams, output_retention, time, constants,
            publication_allowed, environment))
    end
    return Tuple(targets)
end

@generated function _assemble_runtime_call_targets(::PreparedContextCallSchema{C},
    compiled, environment_bindings, bindings::Tuple, temporal_streams,
    output_retention, time, constants, publication_allowed, environment,
) where {C}
    _validate_prepared_context_calls(C)
    bindings_vars = [gensym(:binding) for _ in 1:fieldcount(C)]
    checks = Any[]
    constructions = Any[]
    for (index, CT) in enumerate(fieldtypes(C))
        Binding = fieldtype(CT, :binding)
        Schema = fieldtype(CT, :batch_schema)
        binding = bindings_vars[index]
        push!(checks, :($binding = getfield(bindings, $index)))
        push!(checks, :($binding isa $Binding || throw(ArgumentError("A call declaration is outside its prepared context schema."))))
        for (argument, field) in ((:compiled,:compiled), (:environment_bindings,:environment_bindings),
            (:temporal_streams,:temporal_streams), (:output_retention,:output_retention), (:constants,:constants))
            push!(checks, :($argument isa $(fieldtype(CT, field)) || throw(ArgumentError("A call owner is outside its prepared context schema."))))
        end
        push!(constructions, :(CallTargets(compiled::$(fieldtype(CT,:compiled)),
            environment_bindings::$(fieldtype(CT,:environment_bindings)), $binding::$Binding,
            temporal_streams::$(fieldtype(CT,:temporal_streams)), output_retention::$(fieldtype(CT,:output_retention)),
            time, constants::$(fieldtype(CT,:constants)), publication_allowed, environment;
            batch_schema=$(QuoteNode(Schema())))::$CT))
    end
    result = Expr(:tuple, constructions...)
    return quote
        length(bindings) == $(fieldcount(C)) || throw(ArgumentError("Prepared context call count changed."))
        # Validate ALL declarations and owners before constructing a child.
        $(checks...)
        return $result
    end
end

@inline _clone_call_execution_batches(batches::Vector{B}) where {B<:CompiledExecutionBatch} = copy(batches)

function _materialize_prepared_call_execution_batches!(schema::PreparedExecutionBatchSchema,
    targets::CallTargets,
)
    if targets.tracks_full_membership
        _synchronize_tracked_call_targets!(targets)
    end
    _call_targets_preparation_is_current(targets, targets.compiled,
        targets.environment_bindings, targets.temporal_streams,
        targets.output_retention, targets.constants) && return targets.execution_batches
    if targets.tracks_full_membership
        _observe_compiled_call_membership!(targets.compiled, targets.binding;
            resolve_current=!bindings_dirty(targets.compiled.model))
    end
    batches = _compiled_call_execution_batches(targets.compiled,
        targets.environment_bindings, targets.binding, targets.temporal_streams,
        targets.output_retention, targets.constants;
        cohort_schema=_execution_cohort_schema(schema), batch_schema=schema)
    if targets.tracks_full_membership
        _retire_call_cohort_targets!(targets.temporal_streams, targets.binding, batches;
            schema=_execution_cohort_schema(schema), batch_schema=schema)
    end
    # Publish a complete validated replacement, preserving retained lease shells.
    targets.execution_batches = batches
    targets.last_single_snapshot = nothing
    targets.preparation = _call_targets_preparation(targets.compiled,
        targets.environment_bindings, targets.binding, targets.temporal_streams,
        targets.output_retention, targets.constants)
    return batches
end

@generated function _prepared_runtime_temporal_inputs(::Type{I}, inputs::Tuple, streams) where {I<:Tuple}
    entries = Expr[]
    for (index, R) in enumerate(fieldtypes(I))
        if R <: CompiledTemporalInput
            push!(entries, :(getfield(inputs, $index)::$R))
        else
            R <: RuntimeTemporalInput || error("Invalid prepared temporal-input schema.")
            C, S = fieldtype(R, :compiled), fieldtype(R, :source_streams)
            push!(entries, :(_prepared_runtime_temporal_input($R,
                getfield(inputs, $index)::$C, streams)))
        end
    end
    return quote
        length(inputs) == $(fieldcount(I)) || throw(ArgumentError("Prepared temporal-input count changed."))
        return $(Expr(:tuple, entries...))
    end
end

function _prepared_runtime_temporal_input(::Type{R}, input::C, streams) where {C,S,R<:RuntimeTemporalInput{C,S}}
    sources = if input.binding.multiplicity === :many
        _prepared_temporal_sources(S, streams, input)
    else
        source = _runtime_temporal_source_stream(streams, input, 1)
        source isa S || throw(ArgumentError("A temporal producer stream is outside its prepared schema."))
        source::S
    end
    return R(input, sources)
end

function _prepared_temporal_sources(::Type{Vector{S}}, streams, input) where {S}
    all(isconcretetype,Base.uniontypes(S)) || throw(ArgumentError("Many temporal inputs need explicit producer stream types."))
    sources = Vector{S}()
    sizehint!(sources, length(input.binding.source_ids))
    for index in eachindex(input.binding.source_ids)
        source = _runtime_temporal_source_stream(streams, input, index)
        source isa S || throw(ArgumentError("A temporal producer stream is outside its prepared schema."))
        push!(sources, source::S)
    end
    return sources
end

@generated function _prepared_temporal_sources(::Type{S}, streams, input) where {S<:Tuple}
    entries = [quote
        source = _runtime_temporal_source_stream(streams, input, $index)
        source isa $(fieldtype(S,index)) || throw(ArgumentError("A temporal producer stream is outside its prepared schema."))
        source::$(fieldtype(S,index))
    end for index in 1:fieldcount(S)]
    return quote
        length(input.binding.source_ids) == $(fieldcount(S)) ||
            throw(ArgumentError("An ordered temporal source schema changed its runtime cardinality."))
        return $(Expr(:tuple, entries...))
    end
end

function _prepared_local_runtime_output(::Type{O}, status, application, object_id,
    streams, retention, initialize_missing,
) where {V,S,R,O<:RuntimeOutputStream{V,S,R}}
    key = _model_stream_key(application.id, object_id, V)
    stream = get(streams, key, nothing)
    if isnothing(stream)
        initialize_missing || throw(ArgumentError("A prepared retained output has no initialized stream."))
        stream = _model_new_output_stream(getproperty(status,V), retention, application.id, V)
        stream isa S || throw(ArgumentError("A newborn output stream is outside its prepared schema."))
        streams[key] = stream
    end
    reference = refvalue(status,V)
    stream isa S && reference isa R || throw(ArgumentError("A retained output reference is outside its prepared schema."))
    return O(stream::S, reference::R,
        get(retention.dependency_horizons,(application.id,V),0.0))
end

function _prepared_distributed_runtime_output(::Type{O}, output_targets, application,
    streams, retention,
) where {V,B,S,R,O<:RuntimeDistributedOutputStream{V,B,S,R}}
    target = getproperty(output_targets,V)
    binding = target.binding
    binding isa B || throw(ArgumentError("A distributed output owner is outside its prepared schema."))
    references = getproperty(binding.columns,V)
    references isa R || throw(ArgumentError("A distributed output column is outside its prepared schema."))
    sources = _prepared_distributed_output_sources(S, streams, binding, application.id, V)
    return O(binding::B, sources::S, references::R,
        get(retention.dependency_horizons,(application.id,V),0.0))
end

function _prepared_distributed_output_sources(::Type{Vector{S}}, streams, binding, application_id, variable) where {S}
    sources = Vector{S}()
    sizehint!(sources,length(binding.destination_ids))
    for object_id in binding.destination_ids
        source = get(streams,_model_stream_key(application_id,object_id,variable),nothing)
        !isnothing(source) && source isa S || throw(ArgumentError("A distributed retained stream is outside its prepared schema."))
        push!(sources,source::S)
    end
    return sources
end

@generated function _prepared_distributed_output_sources(::Type{S}, streams, binding, application_id, variable) where {S<:Tuple}
    entries = [quote
        source = get(streams,_model_stream_key(application_id,binding.destination_ids[$index],variable),nothing)
        !isnothing(source) && source isa $(fieldtype(S,index)) || throw(ArgumentError("A distributed retained stream is outside its prepared schema."))
        source::$(fieldtype(S,index))
    end for index in 1:fieldcount(S)]
    return quote
        length(binding.destination_ids) == $(fieldcount(S)) || throw(ArgumentError("An ordered distributed stream schema changed cardinality."))
        return $(Expr(:tuple,entries...))
    end
end

@generated function _prepared_runtime_outputs(::Type{O}, status, output_targets,
    application, object_id, compiled, streams, retention, initialize_missing,
) where {O<:Tuple}
    entries = Expr[]
    for R in fieldtypes(O)
        if R <: RuntimeOutputStream
            push!(entries,:(_prepared_local_runtime_output($R,status,application,
                object_id,streams,retention,initialize_missing)))
        elseif R <: RuntimeDistributedOutputStream
            push!(entries,:(_prepared_distributed_runtime_output($R,output_targets,
                application,streams,retention)))
        else
            error("Invalid prepared output-binding schema.")
        end
    end
    return quote
        outputs = $(Expr(:tuple,entries...))
        if initialize_missing
            # Targeted newborns own a pre-barrier private view: it is not in
            # compiled.status_views_by_target yet. Validate this real view's
            # local output names here; each exact Ref/stream was checked above.
            expected = isnothing(retention) ? () : get(retention.retained_outputs_by_application,application.id,())
            local_count = 0
            for variable in expected
                variable in _model_output_names(application) || continue
                local_count += 1
                local_count <= length(outputs) &&
                    _runtime_output_variable(outputs[local_count]) === variable ||
                    throw(ArgumentError("Prepared newborn retained output names changed."))
            end
            local_count == length(outputs) ||
                throw(ArgumentError("Prepared newborn retained output count changed."))
        else
            _model_execution_outputs_match(outputs,compiled,application,object_id,
                retention,streams) || throw(ArgumentError("Prepared retained output names or ownership changed."))
        end
        return outputs
    end
end

function _call_cohort_admission(::OpenExecutionBatchSchema, schema)
    return schema
end
function _call_cohort_admission(batch_schema::PreparedExecutionBatchSchema, schema)
    expected = _execution_cohort_schema(batch_schema)
    schema isa OpenExecutionCohortSchema || typeof(schema) === typeof(expected) ||
        throw(ArgumentError("Prepared call batch and cohort schemas disagree."))
    return expected
end

@inline _call_batch_schema_for_application(::OpenExecutionBatchSchema, application) = OpenExecutionBatchSchema()
@generated function _call_batch_schema_for_application(::PreparedExecutionBatchSchema{BT}, application::A) where {BT,A}
    batches = [B for B in _prepared_execution_batch_types(BT) if fieldtype(B,:application) === A]
    isempty(batches) && return :(throw(ArgumentError("A callee application is outside its prepared batch schema.")))
    schema = PreparedExecutionBatchSchema{Vector{Union{batches...}}}()
    return QuoteNode(schema)
end

@generated function _execution_group_batch_schema(group::G) where {G<:CompiledApplicationExecutionGroup}
    M = fieldtype(G,:membership)
    if !(fieldtype(M,:schema) <: ClosedExecutionCohortSchema)
        return :(OpenExecutionBatchSchema())
    end
    BT = fieldtype(G,:batches)
    candidates = BT <: Vector ? Base.uniontypes(eltype(BT)) : fieldtypes(BT)
    for B in candidates
        isconcretetype(B) && B <: CompiledExecutionBatch || return :(OpenExecutionBatchSchema())
        Target = eltype(fieldtype(B,:targets))
        Context = fieldtype(Target,:context)
        Context <: RunContext || return :(OpenExecutionBatchSchema())
        Calls = fieldtype(Context,:calls)
        for CT in fieldtypes(Calls)
            fieldtype(CT,:batch_schema) <: PreparedExecutionBatchSchema || return :(OpenExecutionBatchSchema())
        end
    end
    return QuoteNode(PreparedExecutionBatchSchema{BT}())
end
_execution_group_batch_schema(::Nothing) = OpenExecutionBatchSchema()


function _prepared_execution_group(application, schema::PreparedExecutionBatchSchema{BT}, cohorts) where {BT}
    BT <: Vector || throw(ArgumentError("A growing prepared group needs a finite Vector batch schema."))
    membership = _new_execution_cohort_membership(cohorts,nothing,application.id,0,
        _execution_cohort_schema(schema))
    return CompiledApplicationExecutionGroup(application,BT(),membership)
end

# This is a host preparation over actual, already initialized objects at step0.
# The transient whole-application schema map is discarded after compilation.
function _prepare_execution_batch_schemas(simulation::Simulation, schemas::NamedTuple)
    iszero(simulation.current_step) || throw(ArgumentError("Execution batch schemas must be prepared before the first step."))
    bindings_dirty(simulation.model) && throw(ArgumentError("Prepare current bindings before admitting execution schemas."))
    _prepared_application_schema_order(simulation.compiled,schemas)
    for location in values(simulation.temporal_streams.cohorts.locations)
        target = _execution_cohort_target(location)
        cache = target.call_context_cache
        !cache.in_use && isnothing(cache.evaluation) && iszero(cache.execution_stamp[]) ||
            throw(ArgumentError("Execution schemas cannot replace a used or leased timeline."))
    end
    storage = RuntimeStorage(simulation.temporal_streams.streams)
    plan = compile_model_execution_plan(simulation.compiled,simulation.environment_bindings,
        storage,simulation.output_retention,simulation.constants; batch_schemas=schemas)
    closed_groups = Tuple(plan.groups)
    closed_slots = Tuple(plan.groups_by_application_slot)
    closed = CompiledExecutionPlan(plan.cohorts,plan.topology,closed_groups,
        plan.batches,closed_slots,plan.schedule,plan.model_revision,plan.environment_revision)
    return Simulation(simulation.model,simulation.compiled,simulation.environment_bindings,
        closed,simulation.output_retention,storage,simulation.output_datetimes,
        simulation.output_requests,simulation.output_request_matchers,
        simulation.output_request_targets,simulation.output_request_model_revision,
        simulation.runtime_revision,simulation.current_step,simulation.constants,
        simulation.performance)
end

_batch_output_publication(::OpenExecutionBatchSchema,retention,application) =
    _compiled_output_publication(retention,application)

@generated function _batch_output_publication(::PreparedExecutionBatchSchema{BT}, retention,
    application::A,
) where {BT,A}
    publications = unique(fieldtype(B,:output_publication) for B in _prepared_execution_batch_types(BT)
        if fieldtype(B,:application) === A)
    branches = Expr[]
    for O in publications
        V = fieldtype(O,:variables)
        isconcretetype(V) && V <: Tuple || error("Prepared publication variables need a fixed tuple schema.")
        names = Expr(:tuple, [:(variables[$index]::$(fieldtype(V,index))) for index in 1:fieldcount(V)]...)
        push!(branches, :(length(variables) == $(fieldcount(V)) &&
            return $O($names,$(!iszero(fieldcount(V))))))
    end
    return quote
        variables = isnothing(retention) ? () :
            get(retention.retained_outputs_by_application,application.id,())
        $(branches...)
        throw(ArgumentError("Retained publication shape is outside its prepared batch schema."))
    end
end

@inline function _compatible_execution_batch(schema,batch,application,provider,publication)
    isnothing(batch) && return nothing
    return _with_execution_batch(schema,batch) do actual
        _execution_batch_matches(actual,application,provider,publication) ? actual : nothing
    end
end

_prepared_call_name(::Type{<:CompiledModelCallBinding{P}}) where {P} = _prepared_call_plan_name(P)
_prepared_call_plan_name(::Type{<:CompiledModelCallPlan{NAME}}) where {NAME} = NAME

# Host-only type lowering of an OBSERVED real batch's context. No current
# target, callback, status value or model parameter is sampled or reconstructed.
function _execution_batch_type_with_call_schemas(::Type{B}, schemas::NamedTuple) where {B<:CompiledExecutionBatch}
    Target = eltype(fieldtype(B,:targets))
    Context = fieldtype(Target,:context)
    Context <: RunContext || throw(ArgumentError("Prepared calls need a real context type."))
    calls = fieldtype(Context,:calls)
    names = Tuple(_prepared_call_name(fieldtype(CT,:binding)) for CT in fieldtypes(calls))
    Set(keys(schemas)) == Set(names) || throw(ArgumentError("Provide one explicit schema for each declared call."))
    prepared_calls = map(fieldtypes(calls)) do CT
        Binding = fieldtype(CT,:binding)
        schema = getproperty(schemas,_prepared_call_name(Binding))
        schema isa PreparedExecutionBatchSchema || throw(ArgumentError("Calls need explicit batch schemas."))
        BT = only(typeof(schema).parameters)
        actual_batches = _prepared_call_mode(Binding) === :initializer ? Tuple{} : BT
        return CallTargets{fieldtype(CT,:compiled),fieldtype(CT,:environment_bindings),Binding,
            fieldtype(CT,:temporal_streams),fieldtype(CT,:output_retention),
            fieldtype(CT,:constants),actual_batches,typeof(schema)}
    end
    C = Tuple{prepared_calls...}
    parameters = collect(Context.parameters)
    parameters[3] = C
    prepared_context = Core.apply_type(RunContext,parameters...)
    parameters = collect(Target.parameters)
    parameters[9] = prepared_context
    prepared_target = Core.apply_type(CompiledExecutionTarget,parameters...)
    I = fieldtype(prepared_target,:object_id)
    Rows = ExecutionCohortRows{prepared_target,ExecutionCohort{prepared_target,I}}
    return CompiledExecutionBatch{fieldtype(B,:application),Rows,
        fieldtype(B,:environment_provider),fieldtype(B,:output_publication)}
end

@generated function _current_call_binding_for_application(compiled,
    application::CompiledModelApplication{P}, binding::B,
) where {P,B<:CompiledModelCallBinding}
    plans = fieldtype(P,:call_plans)
    Plan = fieldtype(B,:plan)
    index = findfirst(==(Plan),collect(fieldtypes(plans)))
    isnothing(index) && return :(throw(ArgumentError("A retained call no longer has its prepared declaration.")))
    CallerId = fieldtype(B,:consumer_id)
    CalleeId = eltype(fieldtype(B,:callee_object_ids))
    Bindings = Tuple{[CompiledModelCallBinding{T,CallerId,CalleeId} for T in fieldtypes(plans)]...}
    return quote
        bindings = get(compiled.call_bindings_by_target,
            (binding.application_id,binding.consumer_id),())
        bindings isa $Bindings || _unprepared_runtime_configuration()
        return getfield(bindings::$Bindings,$index)::$B
    end
end

@inline _admit_newborn_context_cache(::Nothing,cache) = cache
@inline function _admit_newborn_context_cache(::Type{T},cache) where {T<:CompiledExecutionTarget}
    isnothing(cache) && return nothing
    Cache = CallContextCache{fieldtype(T,:context)}
    cache isa Cache || throw(ArgumentError("A retained newborn context is outside its prepared schema."))
    return cache::Cache
end
