# Included inside CompiledRegionsExperiment. No package source is modified.
# This first mixed-region lowering borrows live reference cells and uses narrow
# numerical columns only while a selected batch executes. Read-only broadcasts
# are legal; any output alias reaching another row's ports is rejected.

struct RegionStateColumn{V,R}
    values::V
    sources::R
end

# The optional native-column extension adds a more-specific preparation method
# for canonical RefArray cells already spanning one ordinary Vector in row order.
# No existing RefValue is migrated or invalidated by this hook.
_try_native_region_column(references) = nothing
_is_native_region_column(column) = false

struct RegionState{D,C,W}
    data::D
    read_columns::C
    write_columns::W
    field_count::Int
    unique_field_count::Int
    source_cell_count::Int
    readonly_broadcasts::Int
end

_region_state_strategy(::RegionState) = :columns

mutable struct RegionCellIdentities
    owners::IdDict{Any,Int}
end
RegionCellIdentities() = RegionCellIdentities(IdDict{Any,Int}())

function _region_owner_identity!(ids::RegionCellIdentities, owner)
    get!(ids.owners, owner) do
        length(ids.owners) + 1
    end
end

function _region_cell_identity!(ids::RegionCellIdentities, reference)
    if reference isa Base.RefValue
        return (_region_owner_identity!(ids, reference), 0)
    elseif reference isa Base.RefArray
        array = getfield(reference, :x)
        array isa Vector || throw(ArgumentError(
            "Region RefArray cells require ordinary Vector storage.",
        ))
        return (_region_owner_identity!(ids, array), getfield(reference, :i))
    end
    throw(ArgumentError("Region columns require ordinary RefValue or Vector RefArray cells."))
end

function _region_concrete_vector(items)
    isempty(items) && return items
    T = typeof(first(items))
    all(x -> typeof(x) === T, items) || throw(ArgumentError(
        "One region column requires homogeneous reference types.",
    ))
    return Vector{T}(items)
end

function _region_state_column(references)
    refs = _region_concrete_vector(references)
    T = eltype(typeof(first(refs)))
    isconcretetype(T) && isbitstype(T) || throw(ArgumentError(
        "Region columns require concrete isbits scalar values.",
    ))
    native = _try_native_region_column(refs)
    isnothing(native) || return native
    values = Vector{T}(undef, length(refs))
    for row in eachindex(refs)
        values[row] = refs[row][]
    end
    return RegionStateColumn(values, refs)
end

"""
    prepare_region_state(targets, names, written_names)

Construct narrow typed numerical columns. Canonical/reference carriers remain
unchanged. The region reads each unique port column at its application boundary
and writes only declared outputs back after the original kernels execute.

Within-row aliases retain one numerical cell. A read-only input shared between
rows is accepted. An output may not alias any port belonging to another row.
"""
function prepare_region_state(targets, names::Tuple, written_names::Tuple)
    isempty(targets) && throw(ArgumentError("Cannot compile an empty region."))
    all(name -> name in names, written_names) || throw(ArgumentError(
        "Region write fields must belong to its port schema.",
    ))
    ids = RegionCellIdentities()
    reference_columns = map(names) do name
        [PSE.refvalue(target.status, name) for target in targets]
    end
    token_columns = map(references -> [
        _region_cell_identity!(ids, reference) for reference in references
    ], reference_columns)
    row_owner = Dict{Tuple{Int,Int},Int}()
    shared = Set{Tuple{Int,Int}}()
    for tokens in token_columns, row in eachindex(tokens)
        token = tokens[row]
        if haskey(row_owner, token)
            row_owner[token] == row || push!(shared, token)
        else
            row_owner[token] = row
        end
    end
    for (name, tokens) in zip(names, token_columns)
        name in written_names || continue
        any(token -> token in shared, tokens) && throw(ArgumentError(
            "A region output aliases another row's input or output.",
        ))
    end
    aliases = ntuple(length(names)) do column
        tokens = token_columns[column]
        first_owner = something(findfirst(previous ->
            token_columns[previous][1] == tokens[1], 1:column), column)
        for row in eachindex(tokens)
            # Every row uses the same alias recipe; unusual patterns keep the
            # original executor rather than selecting an invalid Status type.
            first_at_row = something(findfirst(previous ->
                token_columns[previous][row] == tokens[row], 1:column), column)
            first_at_row == first_owner || throw(ArgumentError(
                "Region rows require one within-row alias pattern.",
            ))
        end
        first_owner
    end
    unique_columns = Any[]
    column_by_index = Any[]
    writes = Any[]
    for column in eachindex(names)
        if aliases[column] == column
            value = _region_state_column(reference_columns[column])
            push!(unique_columns, value)
            push!(column_by_index, value)
        else
            push!(column_by_index, column_by_index[aliases[column]])
        end
    end
    written_aliases = Set(aliases[index] for index in eachindex(names)
        if names[index] in written_names)
    for column in sort!(collect(written_aliases))
        push!(writes, column_by_index[column])
    end
    arrays = NamedTuple{names}(Tuple(column.values for column in column_by_index))
    recipe = GP.LocalStateRecipe{names,aliases}()
    data = GP.ColumnData(arrays, recipe, length(targets))
    return RegionState(data, Tuple(unique_columns), Tuple(writes), length(names),
        length(unique_columns), length(row_owner), length(shared))
end

@inline function _region_pull_column!(column::RegionStateColumn)
    @inbounds for row in eachindex(column.sources)
        column.values[row] = column.sources[row][]
    end
    return nothing
end
@inline function _region_push_column!(column::RegionStateColumn)
    @inbounds for row in eachindex(column.sources)
        column.sources[row][] = column.values[row]
    end
    return nothing
end

@inline _region_pull_columns!(::Tuple{}) = nothing
@inline function _region_pull_columns!(columns::Tuple)
    _region_pull_column!(first(columns))
    _region_pull_columns!(Base.tail(columns))
    return nothing
end
@inline _region_push_columns!(::Tuple{}) = nothing
@inline function _region_push_columns!(columns::Tuple)
    _region_push_column!(first(columns))
    _region_push_columns!(Base.tail(columns))
    return nothing
end

@inline pull_region_state!(state::RegionState) = _region_pull_columns!(state.read_columns)
@inline push_region_state!(state::RegionState) = _region_push_columns!(state.write_columns)

function region_state_report(state::RegionState)
    native_count = count(_is_native_region_column, state.read_columns)
    return (rows=state.data.nrows, fields=state.field_count,
        unique_fields=state.unique_field_count, source_cells=state.source_cell_count,
        readonly_broadcast_cells=state.readonly_broadcasts,
        column_payload_bytes=sum((_is_native_region_column(column) ? 0 : sizeof(column.values))
            for column in state.read_columns; init=0),
        native_column_fields=native_count,
        native_column_bytes=sum((_is_native_region_column(column) ? sizeof(column.values) : 0)
            for column in state.read_columns; init=0),
        canonical_storage=native_count == length(state.read_columns) ?
            :existing_native_columns : :borrowed_live_reference_cells,
        canonical_references_replaced=false,
        duplicate_scalar_columns=native_count != length(state.read_columns),
        read_columns=length(state.read_columns), write_columns=length(state.write_columns))
end
