module XPPreparedBatchTiming

using PlantSimEngine, SHA, Test
const PSE = PlantSimEngine
const F = Main.DirectPlannerFixtures
const H = Main.DirectPlannerMeasurements
const M = Main.NativeDownstreamMeasurements
const CR = Main.CompiledRegionsExperiment
const NBM = Main.NewbornBindingMeasurements
const NSM = Main.NewbornBindingSequenceMeasurements
const XP = Main.NativeXPDriver
const PB = Main.NativePBDriver

export BATCH_ARMS, register_xp_prepared_batch_case!, screen_xp_prepared_batch,
    prepared_batch_checks

const BATCH_ARMS = (:bounded_a, :bounded_b, :bounded_sequence)
_backend(arm::Symbol) = arm in (:bounded_a, :bounded_b) ? :bounded_preparation :
    arm === :bounded_sequence ? :bounded_sequence : throw(ArgumentError("Unknown batch arm: $arm"))

Base.@nospecializeinfer @noinline function _construct_batch(config, weather)
    @nospecialize config weather
    instances = Any[]
    for _ in 1:config.batch_size
        push!(instances, Base.invokelatest(NBM._construct_binding_fixture, :xp, config; weather))
    end
    return (; instances)
end

Base.@nospecializeinfer @noinline function _prepare_batch(fixture, config, arm)
    @nospecialize fixture config
    simulations = Any[]
    backend = _backend(arm)
    for instance in fixture.instances
        push!(simulations, Base.invokelatest(NSM.prepare_sequence_arm,
            instance.model, backend; outputs=config.outputs, details=false))
    end
    return simulations
end

Base.@nospecializeinfer @noinline function _execute_batch!(simulations, config)
    @nospecialize simulations config
    for simulation in simulations
        Base.invokelatest(PSE.continue!, simulation; steps=config.steps)
    end
    return nothing
end

Base.@nospecializeinfer @noinline function _observation(simulation)
    @nospecialize simulation
    return (state=Base.invokelatest(F.snapshot, simulation, :xp),
        scientific_rngs=Base.invokelatest(F.scientific_rngs, simulation.model))
end

"""Lossless full per-instance observations with checked identical-value sharing.

Every fresh simulation is independently observed after timing. Equal digests
are merged only after full isequal comparison; the ordered instance map retains
which full observation belongs to each simulation. This reduces redundant raw
evidence for identical fixed-seed trajectories, without omitting any state.
"""
Base.@nospecializeinfer @noinline function _fingerprint_batch(simulations)
    @nospecialize simulations
    observations = Any[]
    instance_map = Any[]
    by_digest = Dict{String,Int}()
    for (index, simulation) in enumerate(simulations)
        observed = Base.invokelatest(_observation, simulation)
        digest = bytes2hex(sha256(repr(observed)))
        position = get(by_digest, digest, 0)
        if iszero(position)
            push!(observations, (digest=digest, observation=observed))
            position = length(observations)
            by_digest[digest] = position
        else
            isequal(observations[position].observation, observed) ||
                error("Scientific observations share a digest but differ in full value")
        end
        push!(instance_map, (instance=index, observation_index=position, digest=digest))
    end
    return (batch_size=length(simulations), instance_map, full_observations=observations,
        representation=:lossless_full_snapshots_with_checked_equal_value_deduplication)
end

Base.@nospecializeinfer @noinline function _independent_instances(simulations)
    @nospecialize simulations
    models = IdDict{Any,Int}()
    statuses = IdDict{Any,Int}()
    references = IdDict{Any,Int}()
    for (index, simulation) in enumerate(simulations)
        haskey(models, simulation.model) && error("Batch reused a scientific model")
        models[simulation.model] = index
        identities = Base.invokelatest(F.identities, simulation.model)
        for status in values(identities.statuses)
            owner = get(statuses, status, index)
            owner == index || error("Status shared across independent batch simulations")
            statuses[status] = index
        end
        for reference in values(identities.references)
            owner = get(references, reference, index)
            owner == index || error("Canonical Ref shared across independent batch simulations")
            references[reference] = index
        end
    end
    return (models=length(models), cross_instance_statuses_disjoint=true,
        cross_instance_canonical_references_disjoint=true,
        scope=:post_execution_identity_proof_no_status_value_reads)
end

Base.@nospecializeinfer @noinline function _work_batch(simulations, fixture, config)
    @nospecialize simulations fixture config
    length(simulations) == length(fixture.instances) == config.batch_size ||
        error("Batch dimensions changed")
    instances = Any[]
    for index in eachindex(simulations)
        push!(instances, Base.invokelatest(CR.downstream_work_report,
            simulations[index], fixture.instances[index].initial_ids))
    end
    return (batch_size=config.batch_size, instances,
        total_simulated_steps=sum(row.steps for row in instances),
        total_final_objects=sum(row.objects for row in instances),
        total_added_objects=sum(length(row.added_ids) for row in instances),
        total_retained_streams=sum(row.streams for row in instances),
        aggregation=:sum_of_actual_independent_simulation_reports)
end

Base.@nospecializeinfer @noinline function _coverage_batch(simulations, config, arm)
    @nospecialize simulations config
    backend = _backend(arm)
    reports = Any[]
    for simulation in simulations
        push!(reports, Base.invokelatest(NSM.sequence_coverage,
            simulation, backend, :xp; details=false, require_newborn=true))
    end
    fields = NSM.ACTUAL_FIELDS
    totals = NamedTuple{fields}(Tuple(sum(getproperty(row.total_actual, name)
        for row in reports) for name in fields))
    own = NamedTuple{fields}(Tuple(sum(getproperty(row.sequence_actual, name)
        for row in reports) for name in fields))
    if arm === :bounded_sequence
        all(row -> row.sequence_actual.newborn_producer_executions > 0, reports) ||
            error("A sequence batch instance executed no own newborn producer instruction")
    else
        all(row -> !row.base_program.enabled && !row.sequence_program.enabled &&
            all(iszero, values(row.total_actual)), reports) ||
            error("A/A control was contaminated by binding instructions")
    end
    return (native_fields=sum(row.native_fields for row in reports),
        driver_units=sum(row.driver_units for row in reports),
        native_driver_units=sum(row.native_driver_units for row in reports),
        batch_arm=arm, underlying_arm=backend, per_instance=reports,
        actual_completions=totals, actual_sequence_completions=own,
        independent_instances=Base.invokelatest(_independent_instances, simulations),
        metadata_work_is_not_kernel_work=true,
        counter_accounting=:sum_actual_per_instance_counts_once,
        measurement_protocol=:xp_prepared_batch_v1,
        statistical_unit=:one_batch_sample,
        placebo_control=arm in (:bounded_a, :bounded_b))
end

"""Construct and prepare independent XP scenes, then execute them as one batch.

Construction, enabling bounded/sequence policies and all preparation remain in
complete cost. Only the execution timer groups already prepared simulations.
Each instance advances its original scientific timeline once. Source forcing
is read at registration and copied for every independently constructed model.
Use a correctness gate before timing; this is warm execution, not cold JIT.
"""
Base.@nospecializeinfer @noinline function register_xp_prepared_batch_case!(
    name::Symbol=:xp_prepared_batch; batch_size::Int=4, steps::Int=12,
    arms=BATCH_ARMS, outputs=:none, seed::Int=1,
    emission_speed::Real=0.2, replace::Bool=false)
    batch_size > 0 && steps > 0 || error("Positive batch dimensions required")
    names = Tuple(Symbol(arm) for arm in arms)
    all(arm -> arm in names, BATCH_ARMS) && length(unique(names)) == length(names) ||
        error("Include both identical A/A controls and the sequence candidate once")
    foreach(_backend, names)
    config = merge(H.construct_config(:xp; steps, nobjects=2, additions=3,
        seed, emission_speed, outputs), (;
        batch_size, underlying_arms=Dict(arm => _backend(arm) for arm in names),
        measurement_protocol=:xp_prepared_batch_v1,
        statistical_unit=:one_batch_sample,
        execution_scope=:advance_each_fresh_prepared_simulation_once,
        complete_cost_scope=:construction_enablement_all_preparation_and_batch_execution,
        per_simulation_normalization=:divide_reported_batch_phase_by_batch_size,
        placebo_pair=(:bounded_a, :bounded_b), sequence_details=false,
        shared_world_cache=false,
        forcing_setup=:read_at_registration_copied_inside_each_fresh_instance))
    weather = CR._xpalm_fixture_weather(steps)
    return M.register_case!(name; config, replace, packages=(PSE, PB.PB, XP.XPalm),
        variants=Tuple(M.VariantSpec(arm) for arm in names),
        construct=(config, variant) -> Base.invokelatest(_construct_batch, config, weather),
        prepare=(fixture, config, variant) -> Base.invokelatest(_prepare_batch,
            fixture, config, variant.name),
        lower=(simulations, fixture, config, variant) -> nothing,
        execute! = (simulations, program, fixture, config, variant) ->
            Base.invokelatest(_execute_batch!, simulations, config),
        fingerprint=(simulations, fixture, config) ->
            Base.invokelatest(_fingerprint_batch, simulations),
        coverage=(simulations, program, fixture, config, variant) ->
            Base.invokelatest(_coverage_batch, simulations, config, variant.name),
        work=(simulations, fixture, config) ->
            Base.invokelatest(_work_batch, simulations, fixture, config))
end

"""Balanced three-arm screen; A/A labels invoke exactly the same backend."""
function screen_xp_prepared_batch(spec; repetitions::Int=6, measure_retained=false)
    return Base.invokelatest(M.screen_case, spec; baseline=:bounded_a,
        repetitions, measure_retained)
end

"""Tiny independent full-science and escaped-reference parity check, no timing."""
Base.@nospecializeinfer @noinline function prepared_batch_checks(;
    batch_size::Int=2, steps::Int=2, outputs=:all)
    batch_size > 0 && steps > 0 || error("Positive batch dimensions required")
    config = merge(H.construct_config(:xp; steps, nobjects=2, additions=3, outputs), (; batch_size))
    fixtures = Dict{Symbol,Any}()
    simulations = Dict{Symbol,Any}()
    previous = Dict{Symbol,Any}()
    evidence = Dict{Symbol,Any}()
    @testset "Independent prepared XP batches and A/A controls" begin
        for arm in BATCH_ARMS
            fixtures[arm] = Base.invokelatest(_construct_batch, config, nothing)
            simulations[arm] = Base.invokelatest(_prepare_batch, fixtures[arm], config, arm)
            previous[arm] = Any[Base.invokelatest(F.identities, sim.model) for sim in simulations[arm]]
            @test Base.invokelatest(_independent_instances, simulations[arm]).models == batch_size
            @test isequal(Base.invokelatest(_fingerprint_batch, simulations[arm]),
                Base.invokelatest(_fingerprint_batch, simulations[:bounded_a]))
        end
        all_simulations = Any[sim for arm in BATCH_ARMS for sim in simulations[arm]]
        @test Base.invokelatest(_independent_instances, all_simulations).models ==
            length(BATCH_ARMS) * batch_size
        for _ in 1:steps
            for arm in BATCH_ARMS
                for simulation in simulations[arm]
                    Base.invokelatest(PSE.step!, simulation)
                end
            end
            expected = Base.invokelatest(_fingerprint_batch, simulations[:bounded_a])
            for arm in BATCH_ARMS
                @test isequal(Base.invokelatest(_fingerprint_batch, simulations[arm]), expected)
                current = Any[Base.invokelatest(F.identities, sim.model) for sim in simulations[arm]]
                evidence[arm] = current
            end
            # Compare transitions against the independently advanced A arm.
            for arm in (:bounded_b, :bounded_sequence), index in 1:batch_size
                @test F.same_identity_transitions(previous[:bounded_a][index], previous[arm][index],
                    evidence[:bounded_a][index], evidence[arm][index])
            end
            for arm in BATCH_ARMS
                previous[arm] = evidence[arm]
            end
        end
        work = Base.invokelatest(_work_batch, simulations[:bounded_a], fixtures[:bounded_a], config)
        for arm in BATCH_ARMS
            @test Base.invokelatest(_work_batch, simulations[arm], fixtures[arm], config) == work
            evidence[arm] = Base.invokelatest(_coverage_batch, simulations[arm], config, arm)
        end
        evidence[:work] = work
    end
    return evidence
end

end # module
