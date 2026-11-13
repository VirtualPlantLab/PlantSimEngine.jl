# Transient values gathered once by the canonical view compiler. These records
# carry real bindings and private snapshots; they are not runtime view owners.
struct _TemporalStatusViewRecipe
    input::Symbol
    binding::Any
    source_applications::Vector{Union{Nothing,Symbol}}
    initial::Any
    storage::Any
    many::Bool
end

# Project copy payloads from real per-input view/carrier metadata, before
# either private snapshot. This is transient metadata, not another owner.
function _temporal_copy_payload_types(V, B, C)
    types = Any[]
    add(T) = isconcretetype(T) && T !== Union{} && !(T in types) && push!(types, T)
    Plan = fieldtype(B, :plan)
    input = fieldtype(Plan, :route).parameters[1]
    many = fieldtype(Plan, :selector) <: Many
    Carrier = fieldtype(B, :carrier)
    if Carrier <: Base.RefValue
        add(eltype(Carrier))
    elseif Carrier <: RefVector
        add(eltype(Carrier))
    elseif Carrier <: ObjectRefVector
        References = eltype(fieldtype(Carrier, :refs))
        for R in Base.uniontypes(References)
            R <: Base.RefValue && isconcretetype(R) && add(eltype(R))
        end
    end
    if C <: Status && input in _status_schema_names(C)
        index = findfirst(isequal(input), _status_schema_names(C))
        Value = eltype(fieldtype(_status_schema_references(C), index))
        add(many && Value <: AbstractVector ? eltype(Value) : Value)
    end
    for View in _model_status_view_family_types(V), TI in fieldtypes(fieldtype(View, :temporal_inputs))
        Other = fieldtype(TI, :binding)
        fieldtype(fieldtype(Other, :plan), :route).parameters[1] === input || continue
        Initial = fieldtype(TI, :initial)
        Storage = eltype(fieldtype(TI, :reference))
        add(many && Initial <: AbstractVector ? eltype(Initial) : Initial)
        add(many && Storage <: AbstractVector ? eltype(Storage) : Storage)
    end
    return Tuple{types...}
end

@inline function _with_temporal_copy_payloads(f::F, ::Nothing, binding, status,
    args::Vararg{Any,N},
) where {F,N}
    return f(nothing, binding, status, args...)
end
@generated function _with_temporal_copy_payload_family(prototype::AbstractVector{V},
    f::F, binding::B, status::C, args::Vararg{Any,N},
) where {V,F,B,C,N}
    Payloads = _temporal_copy_payload_types(V, B, C)
    token = Val{Payloads}()
    return quote
        isempty(prototype) || throw(ArgumentError("Status view family prototypes must be empty."))
        return f($(QuoteNode(token)), binding, status, args...)
    end
end
@inline function _with_temporal_copy_payloads(f::F, schema::CompiledMetadataTable,
    binding, status, args::Vararg{Any,N},
) where {F,N}
    return Base.@inline _with_metadata_entry(_with_temporal_copy_payload_family,
        schema, binding.application_id, f, binding, status, args...)
end

@inline _copy_temporal_status_value(::Nothing, value) = _private_temporal_value(value)
@generated function _copy_temporal_status_value(::Val{Payloads}, value) where {Payloads}
    branches = [:(typeof(value) === $T && return _private_temporal_value(value::$T))
        for T in fieldtypes(Payloads)]
    return quote
        $(branches...)
        throw(ArgumentError("The temporal snapshot payload is outside its prepared input family."))
    end
end

function _gather_temporal_initial(binding::CompiledModelInputBinding, status::Status, payloads)
    initial = _input_value(binding.carrier)
    if isnothing(initial)
        binding.input in propertynames(status) || error(
            "Temporal input `$(binding.input)` on application ",
            "`$(binding.application_id)` has neither a resolved source carrier nor an ",
            "initialized status value. Resolved source objects: ",
            "`$(Tuple(id.value for id in binding.source_ids))`.",
        )
        initial = status[binding.input]
    end
    binding.multiplicity == :many || return _copy_temporal_status_value(payloads, initial)
    initial isa AbstractVector || error(
        "Temporal `Many` input `$(binding.input)` on application ",
        "`$(binding.application_id)` requires a vector-like initialized value; got ",
        "`$(typeof(initial))`.",
    )
    if length(initial) == length(binding.source_ids)
        return Any[_copy_temporal_status_value(payloads, value) for value in initial]
    end
    binding.policy isa PreviousTimeStep && error(
        "Temporal `Many` input `$(binding.input)` on application ",
        "`$(binding.application_id)` resolved $(length(binding.source_ids)) source ",
        "objects but has $(length(initial)) initialized values.",
    )
    isempty(binding.source_ids) && return Any[]
    isempty(initial) && error(
        "Temporal `Many` input `$(binding.input)` on application ",
        "`$(binding.application_id)` needs an initialized element to preallocate ",
        "$(length(binding.source_ids)) temporal values.",
    )
    return Any[_copy_temporal_status_value(payloads, first(initial)) for _ in binding.source_ids]
end

function _collect_status_view_binding!(binding::CompiledModelInputBinding,
    temporal_bindings, many_names, many_ids,
)
    binding.carrier_hint == :temporal_stream && push!(temporal_bindings, binding)
    if binding.multiplicity == :many
        push!(many_names, binding.input)
        push!(many_ids, binding.source_ids)
    end
    return nothing
end

function _validate_status_view_temporal_binding!(binding::CompiledModelInputBinding,
    application, output_names,
)
    binding.input in output_names || return nothing
    error(
        "Application `$(application.id)` declares `$(binding.input)` as both a ",
        "temporal input and an output. A temporal input uses application-local ",
        "storage while outputs publish through canonical status, so this overlap ",
        "is ambiguous. Use distinct names such as `previous_$(binding.input)` for ",
        "the lagged input and `$(binding.input)` for the current output, then map ",
        "the source explicitly.",
    )
end

function _gather_status_view_temporal!(binding::CompiledModelInputBinding,
    recipes, canonical_status, applications_by_id, application_positions,
    distributed_outputs, status_view_schema,
)
    return Base.@inline _with_temporal_copy_payloads(_gather_admitted_status_view_temporal!,
        status_view_schema, binding, canonical_status, recipes, applications_by_id,
        application_positions, distributed_outputs)
end

function _gather_admitted_status_view_temporal!(payloads, binding::CompiledModelInputBinding,
    canonical_status, recipes, applications_by_id, application_positions,
    distributed_outputs,
)
    initial = _gather_temporal_initial(binding, canonical_status, payloads)
    source_applications = Union{Nothing,Symbol}[]
    for source_id in binding.source_ids
        push!(source_applications, _temporal_source_application(
            binding, source_id, applications_by_id, application_positions,
            distributed_outputs,
        ))
    end
    many = binding.multiplicity == :many
    storage = many ? Any[_copy_temporal_status_value(payloads, value) for value in initial] :
        _copy_temporal_status_value(payloads, initial)
    push!(recipes, _TemporalStatusViewRecipe(binding.input, binding,
        source_applications, initial, storage, many))
    return nothing
end

function _compile_model_status_view(model::CompositeModel,
    application::CompiledModelApplication, object_id::ObjectId,
    input_bindings::Tuple, applications_by_id, application_positions,
    distributed_outputs=NoCompiledDistributedOutputs();
    execution_stamp::Base.RefValue{UInt64}, status_view_schema,
    input_binding_storage,
)
    return _with_model_application(applications_by_id, application) do admitted_application
        raw_status = _ensure_model_object_status!(model, object_id)
        return _with_registered_status(model.registry.objects.catalog, raw_status) do canonical_status
            _assemble_model_status_view(model, admitted_application, object_id,
                input_bindings, canonical_status, applications_by_id,
                application_positions, distributed_outputs, execution_stamp,
                status_view_schema, input_binding_storage)
        end
    end
end

# All modes gather the same values, in the original conversion/snapshot order.
# Selection below concerns exact component construction, never scientific logic.
function _assemble_model_status_view(model, application, object_id,
    input_bindings, canonical_status, applications_by_id, application_positions,
    distributed_outputs, execution_stamp, status_view_schema, input_binding_storage,
)
    temporal_bindings = similar(input_binding_storage, 0)
    many_names, many_ids = Symbol[], Any[]
    for binding in input_bindings
        Base.@inline _with_model_input_binding(_collect_status_view_binding!,
            input_binding_storage, binding, temporal_bindings, many_names, many_ids)
    end
    if !isempty(temporal_bindings)
        output_names = Set(_model_output_names(application))
        for binding in temporal_bindings
            Base.@inline _with_model_input_binding(_validate_status_view_temporal_binding!,
                input_binding_storage, binding, application, output_names)
        end
    end
    private_names = Symbol[]
    # Preserve the existing cheap metadata path without a second constructor.
    output_defaults = if isempty(temporal_bindings) && isempty(output_routing(application.spec))
        NamedTuple()
    else
        defaults = _local_output_schema(application.spec)
        for variable in keys(defaults)
            _publish_mode_for_output(application.spec, variable) == :stream_only &&
                push!(private_names, Symbol(variable))
        end
        defaults
    end
    temporal = _TemporalStatusViewRecipe[]
    for binding in temporal_bindings
        Base.@inline _with_model_input_binding(_gather_status_view_temporal!,
            input_binding_storage, binding, temporal, canonical_status,
            applications_by_id, application_positions, distributed_outputs,
            status_view_schema)
    end
    private_values = Any[]
    for name in private_names
        initial, _, _ = _materialize_status_value(model, name,
            getproperty(output_defaults, name); object_id,
            application_id=application.id, origin=:stream_only_private_default,
            private_copy=true, reuse=true)
        push!(private_values, initial)
    end
    seen_many = Set{Symbol}()
    for name in many_names
        name in seen_many && error(
            "Compiled application input `$(name)` has more than one Many binding.")
        push!(seen_many, name)
    end
    parts = (; canonical_status, temporal, private_names, private_values,
        many_names, many_ids, execution_stamp,
        layout_cache=model.registry.objects.layout_cache)
    view = _construct_model_status_view(status_view_schema, application.id, parts)
    return _admit_model_status_view!(status_view_schema, application.id, view)
end

# A homogeneous initial snapshot has the same exact schema as before. Matching
# never constructs a type from an Any value in the finite construction path.
function _status_view_initial_matches(::Type{I}, value, many::Bool) where {I}
    many || return typeof(value) === I
    value isa Vector{Any} || return false
    isempty(value) && return I === Vector{Any}
    first_type = typeof(first(value))
    homogeneous = all(item -> item isa first_type, value)
    I <: Vector || return false
    return homogeneous ? first_type === eltype(I) : I === Vector{Any}
end

function _construct_status_view_initial(::Type{I}, value, many::Bool) where {I}
    _status_view_initial_matches(I, value, many) || throw(ArgumentError(
        "The temporal initial snapshot is outside its prepared view schema."))
    many || return value::I
    values = value::Vector{Any}
    I === Vector{Any} && return values
    T = eltype(I)
    return T[item::T for item in values]
end

function _status_view_storage_matches(::Type{S}, recipe::_TemporalStatusViewRecipe) where {S}
    recipe.many || return typeof(recipe.storage) === S
    values = recipe.storage
    values isa Vector{Any} || return false
    isempty(values) && return S === RefVector{Any}
    first_type = typeof(first(values))
    homogeneous = all(value -> value isa first_type, values)
    return homogeneous ? S <: RefVector && eltype(S) === first_type :
        S === ObjectRefVector{Vector{Base.RefValue}}
end

function _construct_status_view_storage(::Type{S}, recipe::_TemporalStatusViewRecipe) where {S}
    _status_view_storage_matches(S, recipe) || throw(ArgumentError(
        "The temporal storage is outside its prepared view schema."))
    recipe.many || return recipe.storage::S
    values = recipe.storage::Vector{Any}
    return _construct_status_view_storage(S, values)
end
function _construct_status_view_storage(::Type{RefVector{T}}, values::Vector{Any}) where {T}
    return RefVector{T}(Base.RefValue{T}[Ref(value::T) for value in values])
end
# Ordinary JIT supports the same heterogeneous values as before. A finite view
# family cannot infer each erased reference payload from ObjectRefVector alone;
# such candidates are explicitly excluded below, never redirected to this path.
function _construct_status_view_storage(::Type{ObjectRefVector{Vector{Base.RefValue}}},
    values::Vector{Any},
)
    return ObjectRefVector(Base.RefValue[Ref(value) for value in values])
end

function _construct_status_view_reference(::Type{R}, value) where {T,R<:Base.RefValue{T}}
    typeof(value) === T || throw(ArgumentError(
        "The private value is outside its prepared reference schema."))
    return R(value::T)
end

function _construct_status_view_temporal(::Type{TI}, recipe::_TemporalStatusViewRecipe) where {TI<:CompiledTemporalInput}
    B, SA = fieldtype(TI, :binding), fieldtype(TI, :source_applications)
    I, R = fieldtype(TI, :initial), fieldtype(TI, :reference)
    S = eltype(R)
    recipe.binding isa B && recipe.source_applications isa SA || throw(ArgumentError(
        "The temporal input is outside its prepared view schema."))
    initial = _construct_status_view_initial(I, recipe.initial, recipe.many)
    storage = _construct_status_view_storage(S, recipe)
    reference = _construct_status_view_reference(R, storage)
    return TI(recipe.binding::B, recipe.source_applications::SA, initial, reference)
end

# Metadata only: the same exact factory is reused for canonical and private
# statuses. Private result layouts do not enter the canonical registry catalog.
function _status_view_reference_factory(::Type{V}) where {V<:CompiledModelStatusView}
    S, C = fieldtype(V, :status), fieldtype(V, :canonical_status)
    T, P = fieldtype(V, :temporal_inputs), fieldtype(V, :private_outputs)
    BI = fieldtype(V, :bound_inputs)
    isconcretetype(S) && S <: Status && isconcretetype(C) && C <: Status &&
        isconcretetype(T) && T <: Tuple && isconcretetype(P) && P <: NamedTuple &&
        isconcretetype(BI) && BI <: NamedTuple || throw(ArgumentError(
            "A view constructor requires concrete canonical component schemas."))
    all(R -> isconcretetype(R) && R <: Base.RefValue, fieldtypes(P)) ||
        throw(ArgumentError("Private output schemas require concrete reference types."))
    temporal_names = map(fieldtypes(T)) do TI
        isconcretetype(TI) && TI <: CompiledTemporalInput ||
            throw(ArgumentError("Temporal view schemas require concrete input records."))
        B = fieldtype(TI, :binding)
        Route = fieldtype(fieldtype(B, :plan), :route)
        Route.parameters[1]
    end
    names = (fieldnames(P)..., temporal_names...)
    references = Tuple{fieldtypes(P)...,
        (fieldtype(TI, :reference) for TI in fieldtypes(T))...}
    return ExactReferenceFactory(C, references, S, names)
end

function _status_view_bound_carrier_matches(::Type{S}, parts, name::Symbol) where {S}
    index = findfirst(recipe -> recipe.input === name, parts.temporal)
    isnothing(index) || return _status_view_storage_matches(S, parts.temporal[index])
    index = findfirst(isequal(name), parts.private_names)
    isnothing(index) || return typeof(parts.private_values[index]) === S
    return getproperty(parts.canonical_status, name) isa S
end

@generated function _status_view_parts_match(::Type{V}, parts) where {V<:CompiledModelStatusView}
    C, T = fieldtype(V, :canonical_status), fieldtype(V, :temporal_inputs)
    P, BI = fieldtype(V, :private_outputs), fieldtype(V, :bound_inputs)
    checks = Expr[:(parts.canonical_status isa $C), :(length(parts.temporal) == $(fieldcount(T))),
        :(length(parts.private_names) == $(fieldcount(P))),
        :(length(parts.private_values) == $(fieldcount(P))),
        :(length(parts.many_names) == $(fieldcount(BI))),
        :(length(parts.many_ids) == $(fieldcount(BI)))]
    for (index, TI) in enumerate(fieldtypes(T))
        B, SA = fieldtype(TI, :binding), fieldtype(TI, :source_applications)
        I, R = fieldtype(TI, :initial), fieldtype(TI, :reference)
        input = fieldtype(fieldtype(B, :plan), :route).parameters[1]
        append!(checks, [:(parts.temporal[$index].input === $(QuoteNode(input))),
            :(parts.temporal[$index].binding isa $B),
            :(parts.temporal[$index].source_applications isa $SA),
            :(_status_view_initial_matches($I, parts.temporal[$index].initial, parts.temporal[$index].many)),
            :(_status_view_storage_matches($(eltype(R)), parts.temporal[$index]))])
    end
    for (index, name) in enumerate(fieldnames(P))
        R = fieldtype(P, index)
        R <: Base.RefValue || return :(false)
        append!(checks, [:(parts.private_names[$index] === $(QuoteNode(name))),
            :(typeof(parts.private_values[$index]) === $(eltype(R)))])
    end
    for (index, name) in enumerate(fieldnames(BI))
        B = fieldtype(BI, index)
        B <: BoundMany || return :(false)
        I = fieldtype(fieldtype(B, :ids), :ids)
        S = fieldtype(B, :values)
        append!(checks, [:(parts.many_names[$index] === $(QuoteNode(name))),
            :(parts.many_ids[$index] isa $I),
            :(_status_view_bound_carrier_matches($S, parts, $(QuoteNode(name))))])
    end
    return foldl((a, b) -> :($a && $b), checks)
end

@generated function _construct_prepared_model_status_view(::Type{V}, parts) where {V<:CompiledModelStatusView}
    factory = _status_view_reference_factory(V)
    T, P, BI = fieldtype(V, :temporal_inputs), fieldtype(V, :private_outputs), fieldtype(V, :bound_inputs)
    temporal = Expr(:tuple, [:(_construct_status_view_temporal($TI, parts.temporal[$index]))
        for (index, TI) in enumerate(fieldtypes(T))]...)
    private = Expr(:tuple, [:(_construct_status_view_reference($(fieldtype(P, index)), parts.private_values[$index]))
        for index in 1:fieldcount(P)]...)
    edited = Expr(:tuple,
        [:(getfield(private_outputs, $index)) for index in 1:fieldcount(P)]...,
        [:(getfield(getfield(temporal_inputs, $index), :reference)) for index in 1:fieldcount(T)]...)
    status = fieldcount(P) + fieldcount(T) == 0 ? :(parts.canonical_status) :
        :(_construct_status($(QuoteNode(factory)), parts.canonical_status, $edited))
    bound = Expr(:tuple, [begin
        B = fieldtype(BI, index)
        I = fieldtype(fieldtype(B, :ids), :ids)
        S = fieldtype(B, :values)
        :(_compiled_bound_many(parts.many_ids[$index]::$I,
            getproperty(status, $(QuoteNode(name)))::$S))
    end for (index, name) in enumerate(fieldnames(BI))]...)
    return quote
        _status_view_parts_match(V, parts) || throw(ArgumentError(
            "The gathered values are outside their prepared application view family."))
        temporal_inputs = $temporal
        private_outputs = $P($private)
        status = $status
        bound_inputs = $BI($bound)
        return V(parts.execution_stamp, status, parts.canonical_status,
            temporal_inputs, private_outputs, bound_inputs)
    end
end

function _finite_status_view_construction_supported(V)
    # ObjectRefVector intentionally erases the individual freshly allocated
    # Ref payloads. Existing wrappers still work in BI; creating mixed private
    # storage needs additional real source-reference family evidence.
    return all(fieldtypes(fieldtype(V, :temporal_inputs))) do TI
        !(eltype(fieldtype(TI, :reference)) <: ObjectRefVector)
    end
end

@generated function _construct_model_status_view_family(prototype::AbstractVector{V}, parts) where {V}
    families = _model_status_view_family_types(V)
    supported = filter(_finite_status_view_construction_supported, families)
    branches = [:( _status_view_parts_match($T, parts) &&
        return _construct_prepared_model_status_view($T, parts) ) for T in supported]
    return quote
        isempty(prototype) || throw(ArgumentError("Status view family prototypes must be empty."))
        $(branches...)
        throw(ArgumentError("The gathered values are outside supported prepared application view families; mixed private ObjectRefVector storage requires source-reference family evidence."))
    end
end

@inline function _construct_model_status_view(schema::CompiledMetadataTable,
    application_id::Symbol, parts,
)
    return Base.@inline _with_metadata_entry(_construct_model_status_view_family,
        schema, application_id, parts)
end

# Open preparation discovers the real component types, then uses exactly the
# same typed construction function as a finite family. No scientific replay.
function _open_status_view_initial_type(recipe::_TemporalStatusViewRecipe)
    recipe.many || return typeof(recipe.initial)
    values = recipe.initial
    isempty(values) && return Vector{Any}
    T = typeof(first(values))
    return all(value -> value isa T, values) ? Vector{T} : Vector{Any}
end
function _open_status_view_storage_type(recipe::_TemporalStatusViewRecipe)
    recipe.many || return typeof(recipe.storage)
    values = recipe.storage
    isempty(values) && return RefVector{Any}
    T = typeof(first(values))
    return all(value -> value isa T, values) ? RefVector{T} :
        ObjectRefVector{Vector{Base.RefValue}}
end
function _open_status_view_type(parts)
    C = typeof(parts.canonical_status)
    temporals = map(parts.temporal) do recipe
        CompiledTemporalInput{typeof(recipe.binding), typeof(recipe.source_applications),
            _open_status_view_initial_type(recipe),
            Base.RefValue{_open_status_view_storage_type(recipe)}}
    end
    T = Tuple{temporals...}
    P = NamedTuple{Tuple(parts.private_names),
        Tuple{(Base.RefValue{typeof(value)} for value in parts.private_values)...}}
    S = if isempty(parts.private_names) && isempty(parts.temporal)
        C
    else
        factory = _status_construction_recipe!(parts.layout_cache,
            propertynames(parts.canonical_status),
            (parts.private_names..., (recipe.input for recipe in parts.temporal)...))
        original = _status_schema_references(C)
        edited = Tuple{fieldtypes(P)..., (fieldtype(TI, :reference) for TI in temporals)...}
        selections = map(action -> _selected_status_reference_type(action, original, edited), factory.actions)
        Status{typeof(factory).parameters[1], Tuple{selections...}}
    end
    bound_types = map(parts.many_names, parts.many_ids) do name, ids
        Value = if (index = findfirst(recipe -> recipe.input === name, parts.temporal)) !== nothing
            _open_status_view_storage_type(parts.temporal[index])
        elseif (index = findfirst(isequal(name), parts.private_names)) !== nothing
            typeof(parts.private_values[index])
        else
            typeof(getproperty(parts.canonical_status, name))
        end
        Value <: AbstractVector || error("Compiled Many input `$(name)` has non-vector runtime value `$(Value)`.")
        BoundMany{eltype(Value), BoundManyObjectIds{eltype(typeof(ids)),typeof(ids)},Value}
    end
    BI = NamedTuple{Tuple(parts.many_names),Tuple{bound_types...}}
    return CompiledModelStatusView{S,C,T,P,BI}
end
function _construct_model_status_view(::Nothing, application_id::Symbol, parts)
    return _construct_prepared_model_status_view(_open_status_view_type(parts), parts)
end
