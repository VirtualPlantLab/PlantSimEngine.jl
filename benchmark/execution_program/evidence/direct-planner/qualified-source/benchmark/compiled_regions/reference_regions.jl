# Borrow typed declared-port references instead of synchronizing numerical
# scratch columns. The scientific method and per-row publication stay inline;
# the original row order preserves even cross-row physical aliases exactly.

mutable struct RegionReferenceData{C}
    references::C
    nrows::Int
end

mutable struct RegionReferenceState{D}
    data::D
    field_count::Int
    unique_field_count::Int
    source_cell_count::Int
    readonly_broadcasts::Int
    written_field_count::Int
    written_names::Tuple
    appendable::Bool
    metadata_current::Bool
end

_region_state_strategy(::RegionReferenceState) = :references

function prepare_region_reference_state(targets, names::Tuple, written_names::Tuple;
    appendable::Bool=false)
    isempty(targets) && throw(ArgumentError("Cannot compile an empty reference region."))
    all(name -> name in names, written_names) || throw(ArgumentError(
        "Region write fields must belong to its port schema.",
    ))
    ids = RegionCellIdentities()
    token_columns = Any[]
    reference_columns = Any[]
    owners = Dict{Tuple{Int,Int},Int}()
    broadcasts = Set{Tuple{Int,Int}}()
    written_tokens = Set{Tuple{Int,Int}}()
    for name in names
        references = _region_concrete_vector([
            PSE.refvalue(target.status, name) for target in targets])
        T = eltype(typeof(first(references)))
        isconcretetype(T) && isbitstype(T) || throw(ArgumentError(
            "Reference regions require concrete isbits scalar port values.",
        ))
        tokens = [_region_cell_identity!(ids, reference) for reference in references]
        for (row, token) in enumerate(tokens)
            if haskey(owners, token)
                owners[token] == row || push!(broadcasts, token)
            else
                owners[token] = row
            end
        end
        name in written_names && union!(written_tokens, tokens)
        # Whole-column aliases can share their pointer vector. Unlike scratch
        # columns, different within-row alias patterns need no common recipe.
        alias = findfirst(previous -> previous == tokens, token_columns)
        push!(reference_columns, isnothing(alias) ? references : reference_columns[alias])
        push!(token_columns, tokens)
    end
    readonly_broadcasts = count(token -> !(token in written_tokens), broadcasts)
    columns = NamedTuple{names}(Tuple(reference_columns))
    unique_columns = length(unique(objectid(column) for column in reference_columns))
    return RegionReferenceState(RegionReferenceData(columns, length(targets)),
        length(names), unique_columns, length(owners), readonly_broadcasts,
        length(written_names), written_names, appendable, true)
end

@inline pull_region_state!(::RegionReferenceState) = nothing
@inline push_region_state!(::RegionReferenceState) = nothing

function region_state_report(state::RegionReferenceState)
    _refresh_region_reference_metadata!(state)
    # Count retained pointer arrays by identity, not equality of their current
    # Ref contents; this is O(fields) and never scans every source cell.
    seen = IdDict{Any,Nothing}()
    pointer_bytes = 0
    for column in values(state.data.references)
        haskey(seen, column) && continue
        seen[column] = nothing
        pointer_bytes += sizeof(column)
    end
    return (rows=state.data.nrows, fields=state.field_count,
        unique_fields=state.unique_field_count, source_cells=state.source_cell_count,
        readonly_broadcast_cells=state.readonly_broadcasts,
        column_payload_bytes=0, reference_column_bytes=pointer_bytes,
        native_column_fields=0, native_column_bytes=0,
        canonical_storage=:borrowed_live_reference_columns,
        canonical_references_replaced=false, duplicate_scalar_columns=false,
        read_columns=state.unique_field_count, write_columns=state.written_field_count,
        execution_order=:original_rows, cross_row_aliases_supported=true)
end

function _refresh_region_reference_metadata!(state::RegionReferenceState)
    state.metadata_current && return nothing
    ids = RegionCellIdentities()
    owners = Dict{Tuple{Int,Int},Int}()
    broadcasts = Set{Tuple{Int,Int}}()
    written_tokens = Set{Tuple{Int,Int}}()
    # Diagnostics alone need global alias counts after an append. Do not build
    # O(rows × ports) identity tables at every lifecycle barrier.
    for (name, references) in pairs(state.data.references), (row, reference) in pairs(references)
        token = _region_cell_identity!(ids, reference)
        if haskey(owners, token)
            owners[token] == row || push!(broadcasts, token)
        else
            owners[token] = row
        end
        name in state.written_names && push!(written_tokens, token)
    end
    # Counts are reported as source cells and shared cells. The prepared write
    # set remains available through the unchanged model's output declaration.
    state.source_cell_count = length(owners)
    state.readonly_broadcasts = count(token -> !(token in written_tokens), broadcasts)
    state.metadata_current = true
    return nothing
end

@inline @generated function GP._column_numerical_loop!(
    data::RegionReferenceData{C}, kernels::K, environments::E, constants, step,
) where {C,K<:Tuple,E<:Tuple}
    names = C.parameters[1]
    references = [Symbol(:borrowed_cell_, index) for index in eachindex(names)]
    loads = [:( $(references[index]) = @inbounds getproperty(data.references,
        $(QuoteNode(name)))[row]) for (index, name) in enumerate(names)]
    cells = Expr(:tuple, references...)
    constructor = :(PSE.Status(NamedTuple{$(QuoteNode(names))}($cells)))
    calls = Expr[]
    for index in 1:fieldcount(K)
        push!(calls, quote
            kernel = getfield(kernels, $index)
            model = GP._column_model_at(kernel.models, row)
            Base.@inline PSE.run!(model, local_status,
                getfield(environments, $index), constants, kernel.context)
            GP._column_publish!(kernel, local_status, row, step)
        end)
    end
    return quote
        # No SIMD promise or fusion across rows: writes through one row's Ref
        # must be visible to the next row if their canonical cells alias.
        for row in 1:data.nrows
            $(loads...)
            local_status = $constructor
            $(calls...)
        end
        nothing
    end
end

"""Cheap parity gates for borrowed live-reference regions."""
function reference_region_checks(; downstream_builder=nothing, downstream_steps=4)
    reports = NamedTuple[]
    fixtures = [
        (name=:within_row_alias, builder=GP.within_row_alias_fixture, steps=3),
        (name=:cross_row_alias, builder=GP.alias_fixture, steps=3),
        (name=:cross_object_reduction, builder=GP.reduction_fixture, steps=3),
        (name=:growth, builder=GP.growth_fixture, steps=3),
        (name=:updates, builder=GP.updates_fixture, steps=3),
        (name=:cadence_phase, builder=GP.phase_fixture, steps=4),
        (name=:temporal, builder=GP.temporal_fixture, steps=4),
    ]
    isnothing(downstream_builder) || push!(fixtures,
        (name=:downstream, builder=downstream_builder, steps=downstream_steps))
    @testset "Borrowed typed reference regions preserve original order" begin
        for fixture in fixtures, refresh_strategy in (:rebuild, :reuse, :eager),
            compact in (false, true)
            reference = PSE.run!(fixture.builder(); steps=0, outputs=:all)
            simulation = PSE.run!(fixture.builder(); steps=0, outputs=:all)
            program = compile_regions(simulation; regions=true, resolved_calls=false,
                state_strategy=:references, refresh_strategy, compact)
            for _ in 1:fixture.steps
                PSE.continue!(reference; steps=1)
                advance_regions!(program; steps=1)
                @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
            end
            report = region_report(program)
            @test report.state_strategy_requested === :references
            @test !report.canonical_scalar_copy_retained
            @test all(state -> state.column_payload_bytes == 0, report.selected_state)
            if fixture.name in (:within_row_alias, :cross_row_alias)
                @test report.column_row_executions > 0
            end
            PSE.continue!(reference; steps=1)
            PSE.continue!(simulation; steps=1)
            @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
            push!(reports, (fixture=fixture.name, refresh_strategy, compact,
                column_rows=report.column_row_executions,
                removed_records=report.execution_records_removed,
                rebuilds=report.rebuilds))
        end

        for T in (Float32, Float64), refresh_strategy in (:rebuild, :reuse, :eager)
            builder = () -> GP.fixture_builder(nobjects=5, nmodels=3, value_type=T, extras=2)
            reference = PSE.run!(builder(); steps=3, outputs=:all)
            simulation = PSE.run!(builder(); steps=0, outputs=:all)
            program = compile_regions(simulation; resolved_calls=false,
                state_strategy=:references, refresh_strategy, compact=true)
            advance_regions!(program; steps=3)
            observed = GP.fingerprint(simulation)
            @test isequal(observed, GP.fingerprint(reference))
            GP.check_fixture_counts(observed; nobjects=5, nmodels=3, steps=3, value_type=T)
            @test region_report(program).column_row_executions == 45
            @test all(PSE.model_status(simulation.model, row).stage_1 isa T for row in 1:5)
            push!(reports, (fixture=Symbol(:generic_, T), refresh_strategy,
                compact=true, column_rows=program.counters.column_rows,
                removed_records=region_report(program).execution_records_removed,
                rebuilds=program.rebuilds))
        end
    end
    return (; cases=length(reports), reports)
end
