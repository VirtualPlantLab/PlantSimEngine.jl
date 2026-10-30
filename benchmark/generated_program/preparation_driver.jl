# Preparation-only experiment, included after driver.jl. Existing execution
# functions and the stable preparation implementation are left untouched.

mutable struct PreparationProofCache
    references::IdDict{Any,Any}
    status_reasons::IdDict{Any,Symbol}
    seen_owners::IdDict{Any,Any}
    reference_owners::IdDict{Any,Any}
    reference_visits::Int
    cross_row_alias::Bool
end

PreparationProofCache() = PreparationProofCache(
    IdDict{Any,Any}(), IdDict{Any,Symbol}(),
    IdDict{Any,Any}(), IdDict{Any,Any}(), 0, false,
)

function _preparation_references(status)
    # Normal canonical statuses have a concrete NamedTuple of cells. Avoid
    # fetching each heterogeneous field via a runtime Symbol. A backed view
    # still needs the exact getproperty/refvalue semantics used by the stable
    # compiler; this slow branch is preparation-only and cached once.
    return if !hasfield(typeof(status), :backing) || getfield(status, :backing) === nothing
        values(getfield(status, :vars))
    else
        map(name -> PSE.refvalue(status, name), keys(status))
    end
end

function _preparation_canonical_references!(proofs, canonical)
    # The entity identity is already an allocated mutable token. Using the
    # immutable Status itself as an Any dictionary key can box/copy its entire
    # field tuple on every application visit, defeating this cache.
    token = PSE._status_identity(canonical)
    haskey(proofs.references, token) && return proofs.references[token]
    references = _preparation_references(canonical)
    proofs.references[token] = references
    return references
end

@inline _preparation_refvalues_only(::Tuple{}) = true
@inline function _preparation_refvalues_only(references::Tuple)
    first(references) isa Base.RefValue || return false
    return _preparation_refvalues_only(Base.tail(references))
end

@inline _preparation_isbits_values(::Tuple{}) = true
@inline function _preparation_isbits_values(references::Tuple)
    isbitstype(typeof(first(references)[])) || return false
    return _preparation_isbits_values(Base.tail(references))
end

function _preparation_status_reason!(proofs, canonical)
    token = PSE._status_identity(canonical)
    haskey(proofs.status_reasons, token) && return proofs.status_reasons[token]
    references = _preparation_canonical_references!(proofs, canonical)
    reason = !_preparation_refvalues_only(references) ? :unsupported_reference_alias_proof :
        !_preparation_isbits_values(references) ? :mutable_status_values : :eligible
    proofs.status_reasons[token] = reason
    return reason
end

function _preparation_same_references!(proofs, left, right)
    left === right && return true
    # Different runtime views are deliberately proved in full. Identity tokens
    # identify canonical entities, not necessarily a particular aliased view.
    return _program_same_status_references(left, right)
end

function _preparation_direct_reason!(proofs, simulation, group)
    isnothing(simulation.performance) || return :performance_instrumentation
    isempty(group.batches) && return :empty_application
    for batch in group.batches
        batch.environment_provider isa Union{Nothing,PSE.RawGlobalModelEnvironment} ||
            return :environment_sampling_boundary
        for target in batch.targets
            program_effects(typeof(target.model)) === :local || return :unknown_effects
            isempty(target.call_bindings) || return :manual_or_initializer_calls
            isempty(target.input_bindings) || return :temporal_materialization
            isempty(target.bound_inputs) || return :bound_many_inputs
            isempty(target.output_targets) || return :distributed_outputs
            _preparation_same_references!(proofs, target.status, target.canonical_status) ||
                return :noncanonical_status_view
            reason = _preparation_status_reason!(proofs, target.canonical_status)
            reason === :eligible || return reason
            all(output -> output isa PSE.RuntimeOutputStream, target.output_bindings) ||
                return :distributed_publication
        end
    end
    return :eligible
end

function _preparation_index_references!(proofs, references::Tuple, object_id)
    for reference in references
        proofs.reference_visits += 1
        if haskey(proofs.reference_owners, reference)
            if proofs.reference_owners[reference] != object_id
                proofs.cross_row_alias = true
                return nothing
            end
        else
            proofs.reference_owners[reference] = object_id
        end
    end
    return nothing
end

function _preparation_cross_row_aliases!(proofs, groups)
    for group in groups
        isnothing(group) && continue
        for batch in group.batches, target in batch.targets
            status = target.status
            references = if status === target.canonical_status
                token = PSE._status_identity(target.canonical_status)
                if haskey(proofs.seen_owners, token)
                    if proofs.seen_owners[token] != target.object_id
                        # A canonical entity reused by two objects is a
                        # genuine cross-row alias, not a cache hit to ignore.
                        # Empty Status has no value cell that could alias.
                        if !isempty(_preparation_canonical_references!(proofs, target.canonical_status))
                            proofs.cross_row_alias = true
                            return true
                        end
                    end
                    continue
                end
                proofs.seen_owners[token] = target.object_id
                _preparation_canonical_references!(proofs, target.canonical_status)
            else
                # Ordered/temporal/many views can carry different refs despite
                # sharing one canonical object. Keep their complete proof.
                _preparation_references(status)
            end
            _preparation_index_references!(proofs, references, target.object_id)
            proofs.cross_row_alias && return true
        end
    end
    return false
end

function _preparation_unpacked_batch(batch, ::Type{S}, ::Type{O}) where {S,O}
    statuses = Vector{S}(undef, length(batch.targets))
    bindings = Vector{O}(undef, length(batch.targets))
    for row in eachindex(batch.targets)
        target = batch.targets[row]
        statuses[row] = target.status
        bindings[row] = target.output_bindings
    end
    return ProgramDirectBatch(batch, statuses, bindings)
end

function _preparation_packed_bindings(batch, statuses, first_bindings::O) where {O}
    bindings = Vector{O}(undef, length(batch.targets))
    bindings[1] = first_bindings
    for row in 2:length(batch.targets)
        bindings[row] = map(output -> _program_packed_output(output, statuses[row]),
            batch.targets[row].output_bindings)
    end
    return bindings
end

function _preparation_direct_batch(batch, store)
    first_target = first(batch.targets)
    if isnothing(store)
        return _preparation_unpacked_batch(batch, typeof(first_target.status),
            typeof(first_target.output_bindings))
    end
    # The complete-local packing proof already established matching row IDs,
    # schemas and exact refs for every application. Reuse its one row vector
    # rather than repeating erased identity-map construction for every stage.
    statuses = packed_statuses(store)
    first_bindings = map(output -> _program_packed_output(output, first(statuses)),
        first_target.output_bindings)
    return ProgramDirectBatch(batch, statuses,
        _preparation_packed_bindings(batch, statuses, first_bindings))
end

function _preparation_pack_candidate!(proofs, groups)
    nonempty = [group for group in groups if !isnothing(group) && !isempty(group.batches)]
    isempty(nonempty) && return nothing
    all(group -> length(group.batches) == 1, nonempty) || return nothing
    targets = only(first(nonempty).batches).targets
    for group in nonempty
        others = only(group.batches).targets
        length(others) == length(targets) || return nothing
        for row in eachindex(targets)
            others[row].object_id == targets[row].object_id || return nothing
            _preparation_same_references!(proofs, others[row].status, targets[row].status) ||
                return nothing
        end
    end
    return targets
end

function _compile_program_plan_prepared(simulation, strategy, want_packed, block_size)
    schedule = simulation.compiled.scenario_plan.application_schedule
    groups = [simulation.execution_plan.groups_by_application_slot[entry.application_slot]
        for entry in schedule.entries]
    proofs = PreparationProofCache()
    reasons = [isnothing(group) ? :empty_application :
        _preparation_direct_reason!(proofs, simulation, group) for group in groups]
    if _preparation_cross_row_aliases!(proofs, groups)
        reasons = [reason === :eligible ? :cross_row_alias : reason for reason in reasons]
    end
    all_local = all(reason -> reason in (:eligible, :empty_application), reasons)
    store = nothing
    packed_reason = want_packed ? :requires_complete_local_scene : :not_requested
    if want_packed && all_local && !isempty(groups)
        targets = _preparation_pack_candidate!(proofs, groups)
        if isnothing(targets)
            packed_reason = :different_memberships_or_status_schemas
        else
            try
                store = prepare_packed_rows([target.canonical_status for target in targets])
                packed_reason = :eligible
            catch error_
                error_ isa ArgumentError || rethrow()
                packed_reason = :unsupported_packed_schema
            end
        end
    end
    applications = Any[]
    for (index, group) in enumerate(groups)
        if isnothing(group)
            push!(applications, ProgramApplication(index, index,
                schedule.entries[index].application_slot, (), false))
        elseif reasons[index] === :eligible
            batches = Tuple(_preparation_direct_batch(batch, store) for batch in group.batches)
            push!(applications, ProgramApplication(index, index, group.application.slot, batches, true))
        else
            push!(applications, ProgramApplication(index, index, group.application.slot,
                Tuple(group.batches), false))
        end
    end
    nodes = Any[]
    index = 1
    while index <= length(applications)
        stop = index
        limit = strategy === :monolith ? length(applications) : block_size
        if strategy !== :typed
            while stop < length(applications) && stop - index + 1 < limit &&
                _program_compatible(applications[stop], applications[stop + 1], schedule)
                stop += 1
            end
        end
        if stop > index
            push!(nodes, ProgramFusedRegion(index, stop,
                Tuple(only(applications[j].batches) for j in index:stop)))
        else
            push!(nodes, applications[index])
        end
        index = stop + 1
    end
    report = (
        strategy,
        applications=length(applications),
        direct_applications=count(==(:eligible), reasons),
        ordered_applications=count(reason -> !(reason in (:eligible, :empty_application)), reasons),
        reasons=Tuple((application=schedule.entries[i].application_id, reason=reasons[i])
            for i in eachindex(reasons)),
        fused_regions=count(node -> node isa ProgramFusedRegion, nodes),
        fused_applications=sum(node -> node isa ProgramFusedRegion ?
            node.last_entry - node.first_entry + 1 : 0, nodes; init=0),
        packed_requested=want_packed,
        packed_selected=!isnothing(store),
        packed_reason,
        packed_layout=isnothing(store) ? nothing : packed_report(store),
        local_effect_contract=:total_nonescaping_disjoint_status_only,
        monolith_requested=strategy === :monolith,
        monolith_selected=strategy === :monolith && all_local,
        block_size,
        node_types=Tuple(string(nameof(typeof(node))) for node in nodes),
        preparation_strategy=:cached_status_proofs_and_shared_rows,
        preparation_statuses=length(proofs.references),
        preparation_reference_visits=proofs.reference_visits,
        preparation_unique_cells=length(proofs.reference_owners),
        # This experiment changes initial lowering only. Existing normal
        # compiler rebuilds remain correct after a lifecycle invalidation.
        preparation_refresh_strategy=:ordinary_compiler,
    )
    return ProgramPlan(Tuple(nodes), schedule, store, simulation.runtime_revision, all_local, report)
end

"""Reduce repeated preparation work while retaining the same executor/legality checks."""
function compile_prepared_program(simulation; strategy::Symbol=:typed,
    packed::Bool=false, block_size::Int=4)
    strategy in (:typed, :fused, :monolith) || throw(ArgumentError("Unknown strategy $strategy"))
    block_size > 0 || throw(ArgumentError("block_size must be positive"))
    PSE._compiled_source_finalize!(simulation)
    plan = _compile_program_plan_prepared(simulation, strategy, packed, block_size)
    return GeneratedProgram(simulation, plan, strategy, packed, block_size, 0)
end

_preparation_phase(m) = (seconds=m.time, allocated_bytes=m.bytes,
    gc_seconds=m.gctime, compilation_seconds=m.compile_time,
    recompilation_seconds=m.recompile_time)

"""
    probe_preparation(simulation; packed=false)

Attribute the stable implementation's preparation on an already prepared scene.
Run once to warm, then inspect a second probe. Values are phase-local timing and
cumulative allocations, not retained/peak RAM. No simulation step is executed.
"""
function probe_preparation(simulation; packed=false)
    schedule = simulation.compiled.scenario_plan.application_schedule
    groups_phase = @timed [simulation.execution_plan.groups_by_application_slot[entry.application_slot]
        for entry in schedule.entries]
    groups = groups_phase.value
    reasons_phase = @timed [isnothing(group) ? :empty_application :
        _program_direct_reason(simulation, group) for group in groups]
    alias_phase = @timed _program_cross_row_aliases(groups)
    compatibility_phase = @timed begin
        targets = nothing
        if packed && !alias_phase.value && all(reason ->
            reason in (:eligible, :empty_application), reasons_phase.value)
            nonempty = [group for group in groups if !isnothing(group) && !isempty(group.batches)]
            compatible = !isempty(nonempty) &&
                all(group -> length(group.batches) == 1, nonempty)
            if compatible
                candidates = only(first(nonempty).batches).targets
                compatible = all(group -> begin
                    others = only(group.batches).targets
                    length(others) == length(candidates) && all(row ->
                        others[row].object_id == candidates[row].object_id &&
                        _program_same_status_references(others[row].status, candidates[row].status),
                        eachindex(candidates))
                end, nonempty)
                compatible && (targets = candidates)
            end
        end
        targets
    end
    targets = compatibility_phase.value
    pack_phase = @timed (isnothing(targets) ? nothing :
        prepare_packed_rows([target.canonical_status for target in targets]))
    batch_phase = @timed [Tuple(_program_direct_batch(batch, pack_phase.value)
        for batch in group.batches) for (group, reason) in zip(groups, reasons_phase.value)
        if !isnothing(group) && reason === :eligible]
    return (groups=_preparation_phase(groups_phase),
        status_eligibility=_preparation_phase(reasons_phase),
        repeated_alias_proof=_preparation_phase(alias_phase),
        packing_compatibility=_preparation_phase(compatibility_phase),
        packing=_preparation_phase(pack_phase),
        batch_payloads=_preparation_phase(batch_phase),
        applications=length(groups), cross_row_aliases=alias_phase.value,
        reasons=Tuple(reasons_phase.value),
        note=:diagnostic_phases_exclude_final_node_assembly)
end

"""Exact execution/coverage gates for the preparation-only rewrite."""
function preparation_checks(; include_features=false, steps=2)
    cases = NamedTuple[(name=:local, builder=() -> fixture_builder(
        nobjects=3, nmodels=3, extras=2, value_type=Float32))]
    if include_features
        append!(cases, [
            (name=:reduction, builder=reduction_fixture),
            (name=:calls, builder=call_fixture),
            (name=:temporal, builder=temporal_fixture),
            (name=:growth, builder=growth_fixture),
        ])
    end
    reports = NamedTuple[]
    @testset "Preparation-only lowering equivalence" begin
        for case in cases, strategy in (:typed, :fused, :monolith), packed in (false, true)
            expected = PSE.run!(case.builder(); steps, outputs=:all)
            simulation = PSE.run!(case.builder(); steps=0, outputs=:all)
            stable = compile_program(simulation; strategy, packed)
            prepared = compile_prepared_program(simulation; strategy, packed)
            original_report, prepared_report = strategy_report(stable), strategy_report(prepared)
            @test original_report.reasons == prepared_report.reasons
            @test original_report.direct_applications == prepared_report.direct_applications
            @test original_report.fused_applications == prepared_report.fused_applications
            @test original_report.packed_selected == prepared_report.packed_selected
            advance_program!(prepared; steps)
            @test isequal(fingerprint(simulation), fingerprint(expected))
            push!(reports, (case=case.name, strategy, packed,
                statuses=prepared_report.preparation_statuses,
                reference_visits=prepared_report.preparation_reference_visits))
        end
    end
    return (cases=length(reports), reports)
end
