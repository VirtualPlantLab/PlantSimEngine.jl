# SHELVED, UNQUALIFIED scratch-header experiment. The allocation hypothesis
# motivating it was not confirmed: the saved profile identified RegionPlan
# boxing instead. Execution would require a private Status constructor allowing
# a supplied token with `nothing` backing; that allowance is not installed.
# This file is not included by the normal entry point and must not be enabled
# or counted as qualified evidence without an explicit new experiment.
# Isolated scratch-header experiment. Include inside CompiledRegionsExperiment.
# Default column/reference loops and all frozen controls remain unchanged.
# Only an already-audited :local/:local_ports region can use this loop: its
# kernel cannot observe identity/reflection, escape Status, or retain references
# to this scratch header. Canonical Status identities are never substituted.

struct EphemeralRegionData{D}
    source::D
    identity::Base.RefValue{Nothing}
end
@inline function Base.getproperty(data::EphemeralRegionData, name::Symbol)
    name === :nrows && return getfield(data, :source).nrows
    return getfield(data, name)
end

struct EphemeralRegionState{S,D}
    source::S
    data::D
end
_region_state_strategy(state::EphemeralRegionState) = _region_state_strategy(state.source)
@inline pull_region_state!(state::EphemeralRegionState) = pull_region_state!(state.source)
@inline push_region_state!(state::EphemeralRegionState) = push_region_state!(state.source)
region_state_report(state::EphemeralRegionState) = merge(region_state_report(state.source), (
    scratch_status_identity=:unobservable_batch_local_token,
    canonical_identity_replaced=false,
))

@inline @generated function GP._column_numerical_loop!(
    data::EphemeralRegionData{D}, kernels::K, environments::E, constants, step,
) where {D,K<:Tuple,E<:Tuple}
    if D <: RegionReferenceData
        names = D.parameters[1].parameters[1]
        references = [Symbol(:ephemeral_borrowed_cell_, index) for index in eachindex(names)]
        loads = [:( $(references[index]) = @inbounds getproperty(data.source.references,
            $(QuoteNode(name)))[row]) for (index, name) in enumerate(names)]
        cells = Expr(:tuple, references...)
    elseif D <: GP.ColumnData
        names, aliases = D.parameters[2].parameters
        references = [Symbol(:ephemeral_column_cell_, index) for index in eachindex(names)]
        loads = [:( $(references[index]) = Ref(getproperty(data.source.arrays,
            $(QuoteNode(names[index]))), row)) for index in eachindex(names)
            if aliases[index] == index]
        cells = Expr(:tuple, (references[aliases[index]] for index in eachindex(names))...)
    else
        return :(throw(ArgumentError("Unsupported ephemeral region data.")))
    end
    constructor = :(PSE.Status(NamedTuple{$(QuoteNode(names))}($cells), data.identity, nothing))
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
        # Preserve every row and call/publication boundary, including live
        # cross-row aliases in reference regions. This is not a SIMD promise.
        for row in 1:data.source.nrows
            $(loads...)
            local_status = $constructor
            $(calls...)
        end
        nothing
    end
end

function _ephemeral_region_batch(batch::RegionColumnBatch)
    batch.state isa EphemeralRegionState && return batch
    batch.state isa Union{RegionState,RegionReferenceState} || return batch
    models = batch.kernel.models
    if models isa GP.SharedColumnModel
        region_effects(typeof(models.model)) in (:local, :local_ports) || return batch
    else
        all(model -> region_effects(typeof(model)) in (:local, :local_ports), models.models) ||
            return batch
    end
    data = EphemeralRegionData(batch.state.data, Ref(nothing))
    state = EphemeralRegionState(batch.state, data)
    return RegionColumnBatch(batch.application, batch.targets, batch.environment_provider,
        batch.output_publication, batch.kernel, state, batch.counters)
end

"""
    enable_ephemeral_status_regions!(program)

Opt in to a scratch Status header with one unobservable token per audited
region. Canonical registry statuses, cells, and identities remain unchanged.
No ordinary or frozen loop is replaced. Unsupported/lifecycle-rebuilt groups
remain on their ordinary path until explicitly enabled again. Append refresh
therefore conservatively rebuilds wrapped groups instead of using its stage.
"""
function enable_ephemeral_status_regions!(program::CompiledRegionProgram)
    plan = _ensure_regions!(program)
    replacements = IdDict{Any,Any}()
    nodes = map(plan.nodes) do node
        batches = map(node.batches) do batch
            batch isa RegionColumnBatch || return batch
            replacement = _ephemeral_region_batch(batch)
            replacements[batch.targets.object_ids] = replacement
            return replacement
        end
        RegionApplication(node.entry, node.application_slot, batches)
    end
    _install_reused_region_batches!(program.simulation, replacements)
    states = Tuple(merge((application=batch.application.id,), region_state_report(batch.state))
        for node in nodes for batch in node.batches if batch isa RegionColumnBatch)
    report = merge(plan.report, (selected_state=states, scratch_status_requested=true,
        scratch_status_contract=:audited_no_identity_reflection_or_escape))
    program.plan = RegionPlan(nodes, plan.schedule, plan.runtime_revision,
        plan.environment_revision, report)
    return program
end

function advance_ephemeral_regions!(program::CompiledRegionProgram; steps::Integer=1)
    steps >= 0 || throw(ArgumentError("steps must be non-negative"))
    for _ in 1:steps
        enable_ephemeral_status_regions!(program)
        advance_regions!(program; steps=1)
    end
    enable_ephemeral_status_regions!(program)
    return program.simulation
end

function ephemeral_status_report(program::CompiledRegionProgram)
    batches = [batch for batch in program.simulation.execution_plan.batches
        if batch isa RegionColumnBatch && batch.state isa EphemeralRegionState]
    return (selected_batches=length(batches),
        selected_rows=sum(batch -> batch.state.data.nrows, batches; init=0),
        scratch_status_identity=:one_unobservable_token_per_audited_region,
        canonical_identity_replaced=false,
        unchanged_default_loops=true)
end

"""Cheap parity and canonical-identity gates; no timings or allocation claims."""
function ephemeral_status_region_checks()
    fixtures = [
        (name=:float32_chain, builder=() -> GP.fixture_builder(nobjects=4, nmodels=2,
            value_type=Float32), steps=3),
        (name=:float64_chain, builder=() -> GP.fixture_builder(nobjects=4, nmodels=2), steps=3),
        (name=:within_row_alias, builder=GP.within_row_alias_fixture, steps=3),
        (name=:cross_row_alias, builder=GP.alias_fixture, steps=3),
        (name=:growth, builder=GP.growth_fixture, steps=3),
        (name=:updates, builder=GP.updates_fixture, steps=3),
        (name=:temporal, builder=GP.temporal_fixture, steps=4),
        (name=:manual_calls, builder=GP.call_fixture, steps=3),
        (name=:spatial_environment, builder=() -> GP.completion_spatial_fixture().model, steps=2),
        (name=:native_columns, builder=() -> native_column_integration_fixture(Float64;
            native=true, nobjects=4, nmodels=2).model, steps=3),
    ]
    reports = NamedTuple[]
    @testset "Ephemeral region headers preserve canonical state and identity" begin
        for fixture in fixtures, state_strategy in (:columns, :references), outputs in (:none, :all)
            reference = PSE.run!(fixture.builder(); steps=0, outputs)
            simulation = PSE.run!(fixture.builder(); steps=0, outputs)
            program = compile_regions(simulation; regions=true, resolved_calls=false,
                compact=true, state_strategy, refresh_strategy=:reuse)
            canonical = Dict(object.id => PSE._status_identity(object.status)
                for object in PSE.model_objects(simulation.model))
            enable_ephemeral_status_regions!(program)
            for batch in simulation.execution_plan.batches
                batch isa RegionColumnBatch && batch.state isa EphemeralRegionState || continue
                @test all(token !== batch.state.data.identity for token in values(canonical))
            end
            for _ in 1:fixture.steps
                PSE.continue!(reference; steps=1)
                advance_ephemeral_regions!(program; steps=1)
                @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
            end
            if fixture.name in (:float32_chain, :float64_chain)
                @test ephemeral_status_report(program).selected_rows == 8
                @test all(PSE._status_identity(PSE.model_status(simulation.model, id)) === token
                    for (id, token) in canonical)
            end
            # Ordinary continuation executes the installed wrapper too.
            PSE.continue!(reference; steps=1)
            PSE.continue!(simulation; steps=1)
            @test isequal(GP.fingerprint(simulation), GP.fingerprint(reference))
            push!(reports, (fixture=fixture.name, state_strategy, outputs,
                report=ephemeral_status_report(program), passed=true))
        end
    end
    return (; cases=length(reports), reports)
end
