# Experimental column storage. This file is included in GeneratedProgramExperiment.
#
# This store deliberately keeps the original canonical Ref cells alive. It is a
# runtime-layout experiment, not a claim that registry memory has been reduced.
# The driver owns synchronization at observation/effect boundaries. Within a
# packed region every alias of one canonical Ref resolves to the same packed
# cell; publication through canonical refs requires push_packed! first.

struct PackedStateColumn{T,R}
    values::Vector{T}
    sources::Vector{R}
    active_rows::Vector{Int}
end

struct PackedStateStore{N,C,S}
    columns::NamedTuple{N,C}
    statuses::Vector{S}
    reference_map::IdDict{Any,Any}
    source_rows::IdDict{Any,Int}
    original_rows::Vector{Any}
    alias_count::Int
    cross_row_alias_count::Int
end

function _packed_column(statuses, name::Symbol)
    reference = PSE.refvalue(first(statuses), name)
    reference isa Base.RefValue || throw(ArgumentError(
        "Packed columns require canonical RefValue cells; field $(name) has $(typeof(reference)).",
    ))
    return _packed_column(statuses, name, reference)
end

function _packed_column(statuses, name::Symbol, ::Base.RefValue{T}) where {T}
    isconcretetype(T) && isbitstype(T) || throw(ArgumentError(
        "Packed columns currently require concrete isbits values; field $(name) has $(T).",
    ))
    sources = Vector{Base.RefValue{T}}(undef, length(statuses))
    values = Vector{T}(undef, length(statuses))
    for (index, status) in enumerate(statuses)
        reference = PSE.refvalue(status, name)
        reference isa Base.RefValue{T} || throw(ArgumentError(
            "Packed field $(name) has heterogeneous canonical cell types at row $(index).",
        ))
        sources[index] = reference
        values[index] = reference[]
    end
    return PackedStateColumn(values, sources, Int[])
end

function _index_packed_column!(reference_map, source_rows, column, row_offset=0)
    aliases = 0
    cross_row_aliases = 0
    for row in eachindex(column.sources)
        source = column.sources[row]
        if haskey(reference_map, source)
            aliases += 1
            cross_row_aliases += source_rows[source] != row + row_offset
        else
            reference_map[source] = Ref(column.values, row)
            source_rows[source] = row + row_offset
            push!(column.active_rows, row)
        end
    end
    return aliases, cross_row_aliases
end

function _packed_status(reference_map, status)
    names = propertynames(status)
    references = map(names) do name
        source = PSE.refvalue(status, name)
        haskey(reference_map, source) || throw(ArgumentError(
            "Status field $(name) does not refer to a cell in this packed region.",
        ))
        reference_map[source]
    end
    # NamedTuple construction recovers the concrete RefArray tuple type even
    # though identity-map lookup was erased during this preparation-only pass.
    return PSE.Status(NamedTuple{names}(references))
end

"""
    prepare_packed_rows(statuses)

Build one typed column per field of a homogeneous canonical-status schema.
Existing scientific methods still receive Status, backed by RefArray cells.
Exact Ref aliases within and across rows map to one packed cell. The report
exposes cross-row aliases so an executor can reject unsafe loop interchange.

Only concrete isbits RefValue fields are accepted by this first prototype.
Unsupported schemas throw ArgumentError before any canonical state is changed.
"""
function prepare_packed_rows(statuses::AbstractVector)
    isempty(statuses) && throw(ArgumentError("Cannot pack an empty status group."))
    all(status -> status isa PSE.Status, statuses) || throw(ArgumentError(
        "Packed rows require PlantSimEngine.Status values.",
    ))
    names = propertynames(first(statuses))
    for (index, status) in enumerate(statuses)
        propertynames(status) == names || throw(ArgumentError(
            "Packed rows require one field schema; row $(index) differs.",
        ))
    end
    columns = NamedTuple{names}(map(name -> _packed_column(statuses, name), names))
    reference_map = IdDict{Any,Any}()
    source_rows = IdDict{Any,Int}()
    aliases = 0
    cross_row_aliases = 0
    for column in values(columns)
        column_aliases, column_cross_row_aliases =
            _index_packed_column!(reference_map, source_rows, column)
        aliases += column_aliases
        cross_row_aliases += column_cross_row_aliases
    end
    first_row = _packed_status(reference_map, first(statuses))
    rows = Vector{typeof(first_row)}(undef, length(statuses))
    rows[1] = first_row
    for row in 2:length(statuses)
        packed = _packed_status(reference_map, statuses[row])
        typeof(packed) === eltype(rows) || throw(ArgumentError(
            "Packed row references did not produce a homogeneous Status schema.",
        ))
        rows[row] = packed
    end
    return PackedStateStore(columns, rows, reference_map, source_rows,
        Any[statuses...], aliases, cross_row_aliases)
end

packed_statuses(store::PackedStateStore) = store.statuses

"""Prepare a view whose original fields must all alias cells in the store."""
function packed_status(store::PackedStateStore, original_status::PSE.Status, row::Integer)
    checkbounds(store.statuses, row)
    original_status === store.original_rows[row] && return store.statuses[row]
    return _packed_status(store.reference_map, original_status)
end

@inline function _pull_packed_column!(column::PackedStateColumn)
    @inbounds for row in column.active_rows
        column.values[row] = column.sources[row][]
    end
    return nothing
end

@inline function _push_packed_column!(column::PackedStateColumn)
    @inbounds for row in column.active_rows
        column.sources[row][] = column.values[row]
    end
    return nothing
end

@inline _pull_packed_columns!(::Tuple{}) = nothing
@inline function _pull_packed_columns!(columns::Tuple)
    _pull_packed_column!(first(columns))
    _pull_packed_columns!(Base.tail(columns))
    return nothing
end

@inline _push_packed_columns!(::Tuple{}) = nothing
@inline function _push_packed_columns!(columns::Tuple)
    _push_packed_column!(first(columns))
    _push_packed_columns!(Base.tail(columns))
    return nothing
end

"""Refresh packed cells after external/canonical mutations, outside local work."""
@inline function pull_packed!(store::PackedStateStore)
    _pull_packed_columns!(values(store.columns))
    return store
end

"""Expose packed results to canonical state and canonical output references."""
@inline function push_packed!(store::PackedStateStore)
    _push_packed_columns!(values(store.columns))
    return store
end

function packed_report(store::PackedStateStore)
    return (
        rows=length(store.statuses),
        fields=length(store.columns),
        unique_cells=length(store.reference_map),
        aliases=store.alias_count,
        cross_row_aliases=store.cross_row_alias_count,
        # Only the numerical column arrays, excluding canonical cells, row
        # wrappers, maps and synchronization metadata. This is not peak RAM.
        column_payload_bytes=sum((sizeof(column.values) for column in values(store.columns)); init=0),
        packed_row_type=string(eltype(store.statuses)),
        canonical_refs_retained=true,
        synchronization=:explicit_boundaries,
    )
end

"""Small storage gates; this performs no benchmark or scientific qualification."""
function packed_storage_checks()
    @testset "Packed scalar storage and alias boundaries" begin
        for T in (Float32, Float64)
            shared = Ref(T(1))
            independent_1 = Ref(T(2))
            independent_2 = Ref(T(4))
            original_1 = PSE.Status((x=shared, y=shared, z=independent_1))
            original_2 = PSE.Status((x=shared, y=Ref(T(3)), z=independent_2))
            original = [original_1, original_2]
            store = prepare_packed_rows(original)
            packed = packed_statuses(store)
            report = packed_report(store)

            @test length(packed) == 2
            @test report.unique_cells == 4
            @test report.aliases == 2
            @test report.cross_row_aliases == 1
            @test report.column_payload_bytes == 6 * sizeof(T)
            @test report.canonical_refs_retained
            @test typeof(packed[1].x) === T
            @test PSE.refvalue(packed[1], :x) isa Base.RefArray
            @test PSE.refvalue(packed[1], :x) === PSE.refvalue(packed[1], :y)
            @test PSE.refvalue(packed[1], :x) === PSE.refvalue(packed[2], :x)

            packed[1].x = T(8)
            @test packed[1].y === T(8)
            @test packed[2].x === T(8)
            @test shared[] === T(1) # Canonical observation requires an explicit push.
            packed[1].z = T(5)
            @test packed[2].z === T(4) # Separate RefArray indices must not alias.
            @test independent_1[] === T(2)
            push_packed!(store)
            @test shared[] === T(8)
            @test independent_1[] === T(5)
            @test independent_2[] === T(4)

            shared[] = T(9)
            independent_2[] = T(6)
            pull_packed!(store)
            @test packed[1].x === T(9)
            @test packed[1].y === T(9)
            @test packed[2].x === T(9)
            @test packed[2].z === T(6)
            @test packed_status(store, original_1, 1) === packed[1]
            partial = PSE.Status((q=shared,))
            @test packed_status(store, partial, 1).q === T(9)
            @test_throws ArgumentError packed_status(store, PSE.Status(q=zero(T)), 1)
            @test_throws BoundsError packed_status(store, original_1, 3)

            mutable_value = T[1, 2]
            mutable_status = PSE.Status(x=mutable_value)
            @test_throws ArgumentError prepare_packed_rows([mutable_status])
            @test mutable_status.x === mutable_value
            @test mutable_value == T[1, 2]
            @test_throws ArgumentError prepare_packed_rows([PSE.Status((x=Ref{Real}(T(1)),))])
            @test_throws ArgumentError prepare_packed_rows([PSE.Status(x=T(1)), PSE.Status(y=T(2))])
            @test_throws ArgumentError prepare_packed_rows([PSE.Status(x=T(1)), PSE.Status(x=one(Int))])
        end
        @test_throws ArgumentError prepare_packed_rows(PSE.Status[])
        @test_throws ArgumentError prepare_packed_rows([nothing])
        empty_schema = prepare_packed_rows([PSE.Status(), PSE.Status()])
        @test packed_report(empty_schema).unique_cells == 0
        @test packed_report(empty_schema).column_payload_bytes == 0
        @test push_packed!(pull_packed!(empty_schema)) === empty_schema
    end
    return (passed=true, numeric_types=("Float32", "Float64"),
        alias_cases=(:within_row, :cross_row, :disjoint_cells),
        synchronization=(:pull, :push), zero_rows=:rejected,
        empty_schema=:supported, unsupported_values=:rejected_before_mutation)
end
