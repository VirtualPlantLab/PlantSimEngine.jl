# Host-only observation proposal. No Julia execution or native admission yet.
module FullXPalmScientificObservation

using SHA
using Random
import PlantSimEngine as PSE
import MultiScaleTreeGraph as MTG
import XPalm
import ..StrictSnapshotObservations as Strict
import ..FiniteExportValues: OpenValues, with_value

const CORE_CODE_SHA256 = "7370c5db17c0fa80dc67df666acf18b81ac845c43953f682b33035be22c19b2f"
const STRICT_CODE_SHA256 = "d3afc5e91bbf6da4e2da74498b905ebbb2c43607fa331fb0f315c1bf32772ab8"
const HISTORICAL_4160_NONE_DIGEST = "a4784783c32476c28d9e11e0090820d542549c6e6d29e4b1aca47932f3efd8ae"
sha(path) = bytes2hex(sha256(read(path)))
# Exact full text, memoized only within this frozen, single-observer world.
const TYPE_LABELS = IdDict{Any,Any}()
include(joinpath(@__DIR__, "status-semantic-types.jl"))
label(T) = get!(() -> semantic_type_label(T), TYPE_LABELS, T)

# Collections of detached protocol RECORDS have a deliberate Vector{Any}
# carrier. Scientific values stay in their live containers; their exact source
# type/element type/shape/bit/alias information is encoded below without erasure.

# HOST REFERENCE ONLY: d3af first produces the entire detached strict record.
# This adapter changes only its record-list carriers. It never receives the
# original scientific input, rewrites a label/value, or supplies an admission.
_stable_reference_records(record::NamedTuple) =
    NamedTuple{keys(record)}(map(_stable_reference_records, values(record)))
_stable_reference_records(record::Tuple) = map(_stable_reference_records, record)
_stable_reference_records(records::AbstractVector) =
    Any[_stable_reference_records(record) for record in records]
_stable_reference_records(record::Union{Nothing,Missing,Symbol,AbstractString,Number}) = record
_stable_reference_records(record) = throw(ArgumentError(
    "Expected a detached d3af protocol record node."))
reference_strict_value(value) = _stable_reference_records(Strict.strict_snapshot_value(value))

# Object/address identities never escape. First encounter assigns a local
# graph label, so two fresh factories can compare actual alias relationships.
mutable struct ScientificGraph{A,F,C}
    admission::A
    strict_encoder::F
    identities::IdDict{Any,Int}
    entities::Vector{Any}
    storage_ids::Dict{UInt,Int}
    status_model::C
    status_owners::IdDict{Any,Any}
end
ScientificGraph(admission=OpenValues(), strict_encoder=reference_strict_value; status_model=nothing) =
    ScientificGraph(admission, strict_encoder, IdDict{Any,Int}(), Any[], Dict{UInt,Int}(), status_model, IdDict{Any,Any}())

@inline function value!(graph::ScientificGraph, value)
    return with_value(graph.admission, value) do actual
        admitted_value!(graph, actual)
    end
end

function admitted_value!(graph::ScientificGraph, value)
    value isa Union{Ptr,Module,Task,IO,WeakRef} && throw(ArgumentError(
        "No scientific export rule for opaque value $(typeof(value)); do not omit it."))
    if value isa Type && contains_status_type(value)
        # Type-valued fields use the SAME Status-leaf projection as enclosing
        # type labels; every Type value without Status keeps the original path.
        return (type=:JuliaType, representation=label(value))
    end
    if value isa Union{Nothing,Missing,Symbol,AbstractString,Number,Type}
        return graph.strict_encoder(value)
    end
    if ismutabletype(typeof(value))
        if haskey(graph.identities, value)
            return (reference=graph.identities[value],)
        end
        index = length(graph.entities) + 1
        graph.identities[value] = index
        push!(graph.entities, nothing) # Publish the label before following cycles.
        graph.entities[index] = payload!(graph, value)
        return (reference=index,)
    end
    return payload!(graph, value)
end

@generated function fields!(graph, value::T) where {T}
    records = [:( (name=$(QuoteNode(name)), defined=isdefined(value, $index),
        value=isdefined(value, $index) ? value!(graph, getfield(value, $index)) : nothing) )
        for (index,name) in pairs(fieldnames(T))]
    return :(Any[$(records...)])
end
function payload!(graph, value)
    # Char and user-defined primitive scalars have no fields. Field reflection
    # alone would silently identify distinct values, e.g. MTG attribute 'a'/'b'.
    # Opaque pointer/process primitives were rejected by admitted_value! above.
    if isprimitivetype(typeof(value))
        return (kind=:primitive_scalar, type=label(typeof(value)),
            representation=repr(value), bits=bitstring(value))
    end
    return (kind=:struct, type=label(typeof(value)), fields=fields!(graph, value))
end
payload!(graph, value::NamedTuple) = (kind=:named_tuple, type=label(typeof(value)),
    names=keys(value), values=Any[value!(graph, item) for item in values(value)])
payload!(graph, value::Tuple) = (kind=:tuple, type=label(typeof(value)),
    values=Any[value!(graph, item) for item in value])
payload!(graph, value::Ref) = (kind=:reference_cell, type=label(typeof(value)),
    assigned=isassigned(value), value=isassigned(value) ? value!(graph, value[]) : nothing,
    fields=fields!(graph, value))

function payload!(graph, value::AbstractDict)
    # Retain public iteration order as well as all key/value types and values.
    # In particular this does not replace ColumnarAttrs by an empty dictionary.
    return (kind=:dictionary, type=label(typeof(value)),
        key_type=label(keytype(value)), value_type=label(valtype(value)),
        entries=Any[(key=value!(graph, key), value=value!(graph, item)) for (key,item) in value])
end

# OneTo/UnitRange are arrays whose axes contain another OneTo. Reflect their
# finite range fields instead of recursively treating them as general arrays.
payload!(graph, value::AbstractRange) =
    (kind=:range, type=label(typeof(value)), fields=fields!(graph, value))

function payload!(graph, value::AbstractArray)
    storage = Int[get!(() -> length(graph.storage_ids) + 1, graph.storage_ids, UInt(id))
        for id in Base.dataids(value)]
    # Views/reference vectors retain their public values AND their parent/ref
    # fields. Owning Array/BitArray storage headers contain process addresses
    # and spare capacity, so only their public array state is exported.
    fields = value isa Union{Array,BitArray} ? nothing : fields!(graph, value)
    return (kind=:array, type=label(typeof(value)), element_type=label(eltype(value)),
        shape=size(value), axes=Any[value!(graph, axis) for axis in axes(value)],
        storage_aliases=storage, values=Any[value!(graph, value[index]) for index in eachindex(value)], fields)
end

function payload!(graph, value::PSE.TemporalDependencyBuffer)
    # Unused ring slots may be uninitialized. They are not logical samples.
    return (kind=:temporal_dependency_buffer, type=label(typeof(value)),
        element_type=label(eltype(value)), capacity=length(value.times),
        first_slot=value.first_slot, sample_count=value.sample_count,
        values=Any[value!(graph, sample) for sample in value])
end

# One semantic handler is reached recursively by every canonical and kernel
# Status, including nested values. It never reflects a Status header, backing,
# prepared namespace, field order, reference epoch, or header identity.
# Every actually present biological cell retains its real Ref type, assignment,
# value type/bits/shape and alias graph through the unchanged Ref/array methods.
# A real Ref{Nothing} is present; an absent prepared slot supplies no name/cell.
function payload!(graph, status::PSE.Status)
    names = sort!(Symbol[name for name in propertynames(status) if name !== :node]; by=String)
    length(names) == length(unique(names)) || error("Repeated live Status name.")
    if hasproperty(status, :node)
        # Optional adapter metadata is validated, never invented or treated as a
        # biological cell. Official-vs-supplied Status header identity may differ.
        model = graph.status_model
        isnothing(model) && error("Status node metadata needs its actual registry.")
        adapter = model.source_adapter
        node = status.node
        id = get(graph.status_owners, status, nothing)
        isnothing(id) && error("Status node metadata needs an independently declared target owner.")
        get(adapter.object_ids_by_node, node, nothing) == id || error("Status node metadata has the wrong target owner.")
        PSE.source_node(model, id) === node || error("Status node metadata is not the exact live source node.")
        get(adapter.nodes_by_object_id, id, nothing) === node || error("Status node metadata has no exact forward identity.")
        PSE.model_status(model, node) === PSE.model_status(model, id) || error("Status node metadata round trip differs.")
    end
    return (kind=:status_cells_by_name, names=Tuple(names),
        cells=Any[(name=name, present=true, cell=value!(graph, PSE.refvalue(status, name))) for name in names])
end

function payload!(graph, value::Random.AbstractRNG)
    # Compare the complete state of a COPY. Never draw from or seed the live RNG.
    state = copy(value)
    iszero(fieldcount(typeof(state))) && throw(ArgumentError(
        "An opaque RNG without observable state needs an explicit export rule."))
    return (kind=:copied_rng_state, type=label(typeof(value)),
        complete_state=graph.strict_encoder(state))
end

function wire_observation(observation)
    return (schema=:full_xpalm_scientific_observation_v1,
        core=Strict.strict_snapshot_value(observation.core),
        companion=Strict.strict_snapshot_value(observation.companion))
end

function write_observation_new(path, observation)
    ispath(path) && error("Preserve the existing scientific observation.")
    temporary = path * ".partial"
    ispath(temporary) && error("Preserve the prior incomplete export.")
    write(temporary, PSE.JSON.json(wire_observation(observation)))
    mv(temporary, path)
    return (path=path, sha256=sha(path),
        performance_qualification=false, final_qualification=false,
        native_execution_receipt_validated=false)
end

function payload!(graph, node::MTG.Node)
    return (kind=:mtg_node, type=label(typeof(node)),
        id=value!(graph, MTG.node_id(node)), encoding=value!(graph, MTG.node_mtg(node)),
        parent=value!(graph, MTG.parent(node)), children=value!(graph, MTG.children(node)),
        attributes=value!(graph, MTG.node_attributes(node)))
end

# Header ownership is checked within a run but never exported as biological
# equality. Canonical, ordinary kernel and persistent kernel views are declared
# against the actual registry/target id before following any recursive values.
function register_status_owner!(graph, status::PSE.Status, id)
    owner = PSE.ObjectId(id)
    previous = get(graph.status_owners, status, owner)
    previous == owner || error("One Status header was assigned to two target objects.")
    graph.status_owners[status] = owner
    return nothing
end
function register_view_owner!(graph, view, id)
    return with_value(graph.admission, view) do actual
        register_status_owner!(graph, getfield(actual, :status), id)
        register_status_owner!(graph, getfield(actual, :canonical_status), id)
        nothing
    end
end
# Read the actual execution rows on both sides of the introduction of cohorts.
# Historical call batches must never be materialized by an observation.
function persistent_execution_entries(graph, simulation)
    entries = Any[]
    if hasfield(typeof(simulation.temporal_streams), :cohorts)
        for raw_cohort in values(simulation.temporal_streams.cohorts.cohorts)
            with_value(graph.admission, raw_cohort) do cohort
                # Newer cohorts expose the live target through indexing. The
                # historical storage already contains the target or nothing.
                rows = @static isdefined(PSE, :_ExecutionCohortSlot) ? cohort : cohort.rows
                for index in eachindex(cohort.rows)
                    raw_target = rows[index]
                    isnothing(raw_target) && continue
                    with_value(graph.admission, raw_target) do target
                        push!(entries, (owner=cohort.owner, application=cohort.application_id,
                            object_id=target.object_id, model=getfield(target, :model),
                            view=getfield(target, :status_view)))
                    end
                end
            end
        end
        return entries
    end
    seen = IdDict{Any,Set{Any}}()
    function visit(batches, owner)
        isnothing(batches) && return
        for batch in batches, target in batch.targets
            owners = get!(Set{Any}, seen, target)
            owner in owners && continue
            push!(owners, owner)
            app = batch.application.id
            compiled = batch.context_state.compiled
            (isnothing(compiled) || !haskey(compiled.status_views_by_target, (app,target.object_id))) &&
                (compiled = target.context.compiled)
            source = compiled.status_views_by_target[(app, target.object_id)]
            # Private cells are borrowed from the target's actual execution
            # status, including while a cached call keeps an older status view.
            names = keys(source.private_outputs)
            private_refs = NamedTuple{names}(map(name -> PSE.refvalue(target.status, name), names))
            view = (status=target.status, canonical_status=target.canonical_status, private_outputs=private_refs)
            push!(entries, (owner=owner, application=app, object_id=target.object_id,
                model=target.model, view=view))
            cache = target.call_context_cache
            for ctx in (target.context, cache.default, cache.transient)
                isnothing(ctx) && continue
                for calls in ctx.calls
                    binding = calls.binding
                    child_owner = (binding.application_id, binding.consumer_id,
                        PSE._compiled_call_name(binding), PSE._compiled_call_mode(binding))
                    visit(PSE._cached_call_execution_batches(calls), child_owner)
                end
            end
        end
        return nothing
    end
    visit(simulation.execution_plan.batches, nothing)
    return entries
end
function register_all_status_owners!(graph, simulation, objects, entries=persistent_execution_entries(graph, simulation))
    model = PSE.runtime_model(simulation)
    for object in objects
        register_status_owner!(graph, PSE.model_status(model, object.id), object.id)
    end
    for (key, view) in pairs(simulation.compiled.status_views_by_target)
        register_view_owner!(graph, view, last(key))
    end
    for row in entries
        register_view_owner!(graph, row.view, row.object_id)
    end
    return nothing
end

function status_view!(graph, view)
    return with_value(graph.admission, view) do actual
        (status=value!(graph, getfield(actual, :status)),
            canonical_status=value!(graph, getfield(actual, :canonical_status)),
            private_outputs=value!(graph, getfield(actual, :private_outputs)))
    end
end

function persistent_execution_states!(graph, simulation, entries=persistent_execution_entries(graph, simulation))
    key(row) = with_value(graph.admission, row) do actual
        (repr(actual.owner), actual.application, repr(actual.object_id))
    end
    sort!(entries; by=key)
    records = Any[]
    for row in entries
        record = with_value(graph.admission, row) do actual
            (owner=value!(graph, actual.owner), application=actual.application,
                object_id=value!(graph, actual.object_id), model=value!(graph, actual.model),
                view=status_view!(graph, actual.view))
        end
        push!(records, record)
    end
    return records
end

function companion_snapshot(simulation, setup; constants,
    admission=OpenValues(), strict_encoder=reference_strict_value)
    model = PSE.runtime_model(simulation)
    adapter = model.source_adapter
    adapter isa PSE.MTGObjectAdapter || error("The original XPalm MTG adapter is required.")
    adapter.root === setup.palm.mtg || error("The live source MTG was replaced.")
    adapter.status === XPalm._xpalm_initial_status || error("The original import callback was replaced.")
    setup.parameters === setup.palm.parameters || error("Palm parameters lost their original owner.")
    model.environment === setup.weather || error("The original Weather owner was replaced.")
    constants === simulation.constants || error("Observe the actual execution Constants.")
    objects = sort!(collect(PSE.model_objects(model)); by=object -> object.id.value)
    graph = ScientificGraph(admission, strict_encoder; status_model=model)
    entries = persistent_execution_entries(graph, simulation)
    register_all_status_owners!(graph, simulation, objects, entries)
    roots = (palm_parameters=value!(graph, setup.parameters),
        palm_root=value!(graph, setup.palm.mtg),
        initiation_age=value!(graph, setup.palm.initiation_age),
        weather=value!(graph, setup.weather), constants=value!(graph, constants))
    object_rows = Any[]
    for object in objects
        node = PSE.source_node(model, object.id)
        status = PSE.model_status(model, object.id)
        hasproperty(status, :node) && status.node !== node && error("Optional status node metadata is not its exact live MTG node.")
        PSE.model_status(model, node) === status || error("Live node/status round trip differs.")
        get(adapter.nodes_by_object_id, object.id, nothing) === node || error("Forward node identity index differs.")
        get(adapter.object_ids_by_node, node, nothing) == object.id || error("Reverse node identity index differs.")
        attrs = MTG.node_attributes(node)
        haskey(attrs, :plantsimengine_status) && error("Legacy runtime state appeared in the MTG attributes.")
        if object.scale === :Plant
            haskey(attrs, :parameters) && attrs[:parameters] === setup.parameters ||
                error("Plant attributes do not retain the original parameter owner.")
            hasproperty(status, :parameters) && status.parameters === setup.parameters ||
                error("Plant status does not retain the original parameter owner.")
        end
        push!(object_rows, (id=value!(graph, object.id), name=value!(graph, object.name),
            scale=object.scale, kind=object.kind, species=object.species,
            parent=value!(graph, object.parent), children=value!(graph, object.children),
            node=value!(graph, node), geometry=value!(graph, PSE.geometry(object)),
            status=value!(graph, status)))
    end
    applications = Any[]
    for raw_spec in model.applications
        record = with_value(graph.admission, raw_spec) do spec
            (name=spec.name, model=value!(graph, spec.model))
        end
        push!(applications, record)
    end
    application_views = Any[(key=value!(graph, key), view=status_view!(graph, view))
        for (key,view) in sort!(collect(pairs(simulation.compiled.status_views_by_target)); by=pair -> repr(first(pair)))]
    private_states = persistent_execution_states!(graph, simulation, entries)
    # The historical core deliberately makes detached plain array snapshots.
    # Export original stream/sample types and aliases here as well, including
    # temporal-only buffers and histories of removed objects.
    streams = Any[(key=value!(graph, key), stream=value!(graph, stream))
        for (key,stream) in sort!(collect(pairs(PSE.outputs(simulation))); by=pair -> repr(first(pair)))]
    # Only detached records escape. The IdDicts holding live identities die here.
    return (schema=:full_xpalm_companion_v1, roots, objects=object_rows, applications,
        application_views, private_states, streams, entities=graph.entities,
        invariants=(original_callback=true, original_root=true, original_parameter_owner=true,
            original_weather_owner=true, live_node_round_trips=true),
        declared_scope=(public_mtg_attributes=true, geometry=true, reference_alias_graph=true,
            live_canonical_and_persistent_private_states=true,
            copied_complete_model_rng_state=true, private_prebarrier_events=false,
            private_mtg_traversal_and_column_storage_caches=false))
end

function observe_science(simulation, setup; constants, core_snapshot, core_source)
    sha(core_source) == CORE_CODE_SHA256 || error("The historical strict snapshot code differs.")
    method = which(core_snapshot, (typeof(simulation),))
    realpath(String(method.file)) == realpath(core_source) || error("The supplied core function is not from the frozen source.")
    core = core_snapshot(simulation)
    required = (:step,:states,:topology,:histories,:rngs,:source_topology)
    keys(core) == required || error("The complete historical core observation is required.")
    strict_method = which(Strict.content_sha256, (typeof(core),))
    strict_source = String(strict_method.file)
    sha(strict_source) == STRICT_CODE_SHA256 || error("The strict type/bit encoder differs.")
    companion = companion_snapshot(simulation, setup; constants)
    # The unchanged core before/after check detects scientific mutation by the
    # companion. Alias and attribute mutation negatives still need real tests.
    Strict.content_sha256(core_snapshot(simulation)) == Strict.content_sha256(core) ||
        error("The companion changed the scientific state.")
    sha(core_source) == CORE_CODE_SHA256 || error("The observer source changed during observation.")
    sha(strict_source) == STRICT_CODE_SHA256 || error("The strict encoder changed during observation.")
    return (; core, companion)
end

end
