module XPDispatchRefreshMeasurements

using PlantSimEngine, Test
const PSE = PlantSimEngine
const H = Main.DirectPlannerMeasurements
const F = Main.DirectPlannerFixtures
const M = Main.NativeDownstreamMeasurements
const CR = Main.CompiledRegionsExperiment
const NBM = Main.NewbornBindingMeasurements
const NSM = Main.NewbornBindingSequenceMeasurements
const Batch = Main.XPPreparedBatchTiming
const XP = Main.NativeXPDriver
const PB = Main.NativePBDriver
_graph() = getfield(Main, :GraphRowProjection)
_typed() = getfield(Main, :TypedOutputPreparation)
_trusted() = getfield(Main, :TrustedExecutionGroupIndex)

export DISPATCH_ARMS, OPTIONAL_ARMS, dispatch_refresh_policies,
    prepare_dispatch_refresh, dispatch_refresh_coverage, dispatch_refresh_checks,
    register_xp_dispatch_refresh_case!, screen_xp_dispatch_refresh

const DISPATCH_ARMS = (:ordinary_a, :ordinary_b, :bounded_graph, :trusted_index, :typed_barrier)
const OPTIONAL_ARMS = (:trusted_barrier, :trusted_barrier_graph, :typed_graph, :trusted_graph)
const PROTOCOL = :xp_ordinary_dispatch_refresh_v1

function dispatch_refresh_policies(arm::Symbol)
    arm in (DISPATCH_ARMS..., OPTIONAL_ARMS...) ||
        throw(ArgumentError("Unknown ordinary dispatch/refresh arm: $arm"))
    graph = arm in (:bounded_graph, :trusted_barrier_graph, :typed_graph, :trusted_graph)
    trusted = arm in (:trusted_index, :trusted_barrier, :trusted_barrier_graph, :trusted_graph)
    typed = arm in (:typed_barrier, :trusted_barrier, :trusted_barrier_graph, :typed_graph)
    return (; bounded=graph, graph, trusted_index=trusted, typed_output_preparation=typed,
        underlying_arm=graph ? :bounded_preparation : :reference_executor,
        numerical_executor=:ordinary, binding_program=:disabled,
        previous_epoch_lookup=trusted ? :conservative_fallback_only : :disabled)
end

"""Enable independent cold metadata policies inside charged normal preparation.

Both ordinary aliases execute the same ordinary-reference PSE executor with no
bounded metadata, graph projection, binding instructions or prior lookup policy.
The bounded+graph arm is an explicit positive anchor, not an ordinary baseline.
"""
Base.@nospecializeinfer @noinline function prepare_dispatch_refresh(model, arm::Symbol;
    outputs=:none, performance=false, count_calls=false)
    @nospecialize model outputs
    policy = dispatch_refresh_policies(arm)
    policy.graph && Base.invokelatest(_graph().enable_graph_row_projection!, model)
    policy.trusted_index && Base.invokelatest(_trusted().enable_trusted_execution_group_index!, model)
    policy.typed_output_preparation && Base.invokelatest(_typed().enable_typed_output_preparation!, model)
    return Base.invokelatest(H.prepare_arm, model, policy.underlying_arm;
        outputs, performance, count_calls)
end

function _all_nonnegative(counters)
    all(value -> value isa Integer && value >= 0, values(counters)) ||
        error("Invalid completed metadata counters")
    return counters
end

function _typed_counts(report; require_growth=false)
    c = _all_nonnegative(report.counters)
    c.applications_completed == c.initial_applications_completed + c.growth_applications_completed ||
        error("Typed output application phase counts disagree")
    c.objects_prepared == c.initial_objects_prepared + c.growth_objects_prepared ||
        error("Typed output object phase counts disagree")
    c.application_attempts >= c.applications_completed + c.declines ||
        error("Typed output completions exceed actual attempts")
    c.defaults_added <= c.canonical_ports_visited ||
        error("Typed output additions exceed actual canonical port visits")
    if require_growth
        c.growth_applications_completed > 0 && c.growth_objects_prepared > 0 ||
            error("Typed output candidate completed no growth-phase object preparation")
    end
    return c
end

function _trusted_counts(report; require_growth=false)
    c = _all_nonnegative(report.counters)
    c.refresh_attempts == c.certificate_hits + c.certificate_misses ||
        error("Trusted-index certificate hit/miss partition disagrees")
    c.lookup_attempts == c.trusted_group_hits + c.trusted_empty_returns + c.fallback_queries ||
        error("Trusted-index query hit/empty/fallback partition disagrees")
    c.construction_begins >= c.indices_certified + c.indices_rejected ||
        error("Trusted-index certifications exceed construction starts")
    c.fallback_lookups_created <= c.fallback_queries ||
        error("Trusted-index fallback objects exceed actual queries")
    fallback = report.fallback_epoch
    e, v = _all_nonnegative(fallback.counters), _all_nonnegative(fallback.v1.counters)
    e.epoch_attempts == e.epochs_validated + e.epochs_rejected ||
        error("Fallback epoch validation partition disagrees")
    v.lookups == v.slot_hits + v.slot_misses + e.trusted_empty_returns ||
        error("Fallback hit/miss/trusted-empty partition disagrees")
    v.slot_misses == v.absent_slot_misses + v.out_of_range_misses + v.identity_misses ||
        error("Fallback miss-reason partition disagrees")
    e.query_fallbacks == v.slot_misses == v.dictionary_lookups ||
        error("Fallback original-ID dictionary queries disagree")
    v.dictionaries_built <= v.refresh_lookups_created ||
        error("Fallback dictionaries exceed created lookups")
    fallback.dictionary_builds_avoided == v.refresh_lookups_created - v.dictionaries_built ||
        error("Fallback avoided dictionary-build accounting disagrees")
    c.fallback_queries == v.lookups && c.fallback_lookups_created == e.epoch_attempts ||
        error("Trusted-index fallback calls differ from separate epoch namespace")
    if require_growth
        c.indices_certified > 0 && c.certificate_hits > 0 &&
            c.trusted_group_hits > 0 && c.trusted_empty_returns > 0 ||
            error("Trusted-index candidate has no own certified nonempty/empty growth work")
    end
    return c
end

Base.@nospecializeinfer @noinline function dispatch_refresh_coverage(simulation,
    arm::Symbol, kind; instrumented=false, require_growth=kind === :xp)
    @nospecialize simulation
    policy = dispatch_refresh_policies(arm)
    # This existing report also rejects any accidental base/sequence activation.
    ordinary = Base.invokelatest(NSM.sequence_coverage, simulation,
        policy.underlying_arm, kind; details=false, instrumented, require_newborn=false)
    graph = Base.invokelatest(_graph().graph_row_projection_report, simulation)
    typed = Base.invokelatest(_typed().typed_output_preparation_report, simulation)
    trusted = Base.invokelatest(_trusted().trusted_execution_group_index_report, simulation)
    g = _all_nonnegative(graph.counters)
    t = _typed_counts(typed; require_growth=policy.typed_output_preparation && require_growth)
    u = _trusted_counts(trusted; require_growth=policy.trusted_index && require_growth)
    graph.enabled === policy.graph || error("Graph policy differs from arm")
    typed.enabled === policy.typed_output_preparation || error("Typed output policy differs from arm")
    trusted.enabled === policy.trusted_index || error("Trusted index policy differs from arm")
    trusted.fallback_epoch.enabled === policy.trusted_index &&
        trusted.fallback_epoch.v1.enabled === policy.trusted_index ||
        error("Conservative lookup fallback policy contaminated an ordinary control")
    if policy.graph
        g.projections_completed > 0 && g.rows_projected > 0 ||
            error("Bounded graph anchor completed no actual graph tables")
    else
        all(iszero, values(g)) || error("Graph work contaminated ordinary control")
    end
    if policy.typed_output_preparation
        t.applications_completed > 0 && t.objects_prepared > 0 ||
            error("Typed output path completed no actual object preparation")
    else
        all(iszero, values(t)) || error("Typed output work contaminated control")
    end
    policy.trusted_index || all(iszero, values(u)) || error("Trusted work contaminated control")
    if !policy.trusted_index
        all(iszero, values(trusted.fallback_epoch.counters)) &&
            all(iszero, values(trusted.fallback_epoch.v1.counters)) ||
            error("Earlier epoch/v1 work contaminated an independent arm")
    end
    return merge(ordinary, (dispatch_arm=arm, dispatch_policies=policy,
        graph_projection=graph, typed_output_preparation=typed, trusted_execution_index=trusted,
        actual_graph=(projections_completed=g.projections_completed,
            rows_projected=g.rows_projected, edges_projected=g.edges_projected),
        actual_typed_output=t, actual_trusted_index=u,
        actual_trusted_fallback_epoch=trusted.fallback_epoch.counters,
        actual_trusted_fallback_queries=trusted.fallback_epoch.v1.counters,
        measurement_protocol=PROTOCOL, metadata_work_is_not_kernel_work=true,
        ordinary_baseline=arm in (:ordinary_a, :ordinary_b),
        baseline_scope=:ordinary_reference_executor_without_bounded_or_other_candidates))
end

Base.@nospecializeinfer @noinline function _prepare_batch(fixture, config, arm)
    @nospecialize fixture config
    simulations = Any[]
    for instance in fixture.instances
        push!(simulations, Base.invokelatest(prepare_dispatch_refresh, instance.model, arm;
            outputs=config.outputs))
    end
    return simulations
end

function _sum_actual(reports, field)
    names = propertynames(getproperty(first(reports), field))
    return NamedTuple{names}(Tuple(sum(getproperty(getproperty(row, field), name)
        for row in reports) for name in names))
end

function _same_status_shapes(left, right)
    keys(left.statuses) == keys(right.statuses) &&
        keys(left.references) == keys(right.references) || return false
    all(key -> typeof(left.statuses[key]) === typeof(right.statuses[key]), keys(left.statuses)) ||
        return false
    return all(key -> typeof(left.references[key]) === typeof(right.references[key]), keys(left.references))
end

Base.@nospecializeinfer @noinline function _coverage_batch(simulations, config, arm)
    @nospecialize simulations config
    reports = Any[Base.invokelatest(dispatch_refresh_coverage, simulation, arm, :xp)
        for simulation in simulations]
    return (native_fields=sum(row.native_fields for row in reports),
        driver_units=sum(row.driver_units for row in reports),
        native_driver_units=sum(row.native_driver_units for row in reports),
        dispatch_arm=arm, dispatch_policies=dispatch_refresh_policies(arm),
        per_instance=reports, actual_graph=_sum_actual(reports, :actual_graph),
        actual_typed_output=_sum_actual(reports, :actual_typed_output),
        actual_trusted_index=_sum_actual(reports, :actual_trusted_index),
        actual_trusted_fallback_epoch=_sum_actual(reports, :actual_trusted_fallback_epoch),
        actual_trusted_fallback_queries=_sum_actual(reports, :actual_trusted_fallback_queries),
        independent_instances=Base.invokelatest(Batch._independent_instances, simulations),
        counter_accounting=:sum_completed_namespace_per_instance_once,
        measurement_protocol=PROTOCOL, metadata_work_is_not_kernel_work=true,
        statistical_unit=:one_batch_sample, ordinary_baseline=arm in (:ordinary_a, :ordinary_b),
        baseline_scope=:ordinary_reference_executor_without_bounded_or_other_candidates)
end

"""Full per-step original science/history/type/RNG/reference parity, no timing."""
Base.@nospecializeinfer @noinline function dispatch_refresh_checks(kind::Symbol=:xp;
    arm::Symbol=:typed_barrier, steps::Int=2, nobjects::Int=2, outputs=:all)
    kind in (:xp, :pb) || throw(ArgumentError("Expected original :xp or :pb fixture"))
    steps > 0 && nobjects > 0 || error("Positive fixture dimensions required")
    config = H.construct_config(kind; steps, nobjects, outputs)
    evidence = Dict{Symbol,Any}()
    @testset "Ordinary executor versus independent dispatch/refresh candidate" begin
        left = Base.invokelatest(NBM._construct_binding_fixture, kind, config)
        right = Base.invokelatest(NBM._construct_binding_fixture, kind, config)
        reference = Base.invokelatest(prepare_dispatch_refresh, left.model, :ordinary_a; outputs)
        candidate = Base.invokelatest(prepare_dispatch_refresh, right.model, arm; outputs)
        old_reference = Base.invokelatest(F.identities, left.model)
        old_candidate = Base.invokelatest(F.identities, right.model)
        @test keys(old_reference.references) == keys(old_candidate.references)
        @test _same_status_shapes(old_reference, old_candidate)
        @test all(key -> old_reference.references[key] !== old_candidate.references[key], keys(old_reference.references))
        @test isequal(Base.invokelatest(F.snapshot, reference, kind), Base.invokelatest(F.snapshot, candidate, kind))
        @test Base.invokelatest(F.scientific_rngs, left.model) == Base.invokelatest(F.scientific_rngs, right.model)
        for _ in 1:steps
            Base.invokelatest(PSE.step!, reference)
            Base.invokelatest(PSE.step!, candidate)
            @test isequal(Base.invokelatest(F.snapshot, reference, kind), Base.invokelatest(F.snapshot, candidate, kind))
            @test Base.invokelatest(F.scientific_rngs, left.model) == Base.invokelatest(F.scientific_rngs, right.model)
            next_reference = Base.invokelatest(F.identities, left.model)
            next_candidate = Base.invokelatest(F.identities, right.model)
            @test _same_status_shapes(next_reference, next_candidate)
            @test F.same_identity_transitions(old_reference, old_candidate, next_reference, next_candidate)
            old_reference, old_candidate = next_reference, next_candidate
        end
        work = Base.invokelatest(CR.downstream_work_report, candidate, right.initial_ids)
        @test work == Base.invokelatest(CR.downstream_work_report, reference, left.initial_ids)
        evidence[:work] = work
        evidence[:ordinary] = Base.invokelatest(dispatch_refresh_coverage, reference, :ordinary_a, kind)
        evidence[:candidate] = Base.invokelatest(dispatch_refresh_coverage, candidate, arm, kind)
    end
    evidence[:passed] = true
    evidence[:kind] = kind
    evidence[:arm] = arm
    evidence[:steps] = steps
    return evidence
end

"""Five-arm small screen against actual ordinary A/A controls.

The bounded+graph anchor is an explicit different preparation policy. All flags
are enabled inside preparation. Original scientific models, reference statuses,
forcing and lifecycle stay unchanged. Each scientific trajectory is fresh and
observed independently; a batch is one timing sample. No catalogue, precompile,
shared instruction cache, packed state or typed numerical executor is used.
"""
Base.@nospecializeinfer @noinline function register_xp_dispatch_refresh_case!(
    name::Symbol=:xp_dispatch_refresh; batch_size::Int=2, steps::Int=2,
    arms=DISPATCH_ARMS, outputs=:none, seed::Int=1,
    emission_speed::Real=0.2, replace::Bool=false)
    batch_size > 0 && steps > 0 || error("Positive fixture dimensions required")
    names = Tuple(Symbol(arm) for arm in arms)
    all(arm -> arm in names, (:ordinary_a, :ordinary_b, :bounded_graph)) &&
        length(unique(names)) == length(names) || error("Include both ordinary A/A controls and bounded graph anchor once")
    foreach(dispatch_refresh_policies, names)
    config = merge(H.construct_config(:xp; steps, nobjects=2, additions=3,
        seed, emission_speed, outputs), (;
        batch_size, dispatch_policies_by_arm=Dict(arm => dispatch_refresh_policies(arm) for arm in names),
        measurement_protocol=PROTOCOL, statistical_unit=:one_batch_sample,
        execution_scope=:advance_each_fresh_prepared_simulation_once,
        complete_cost_scope=:construction_enablement_all_preparation_and_batch_execution,
        per_simulation_normalization=:divide_reported_batch_phase_by_batch_size,
        placebo_pair=(:ordinary_a, :ordinary_b), numerical_executor=:ordinary,
        binding_instructions=false,
        previous_epoch_lookup=:disabled_on_controls_conservative_fallback_only_for_trusted,
        forcing_setup=:read_at_registration_copied_inside_each_fresh_instance))
    weather = CR._xpalm_fixture_weather(steps)
    return M.register_case!(name; config, replace, packages=(PSE, PB.PB, XP.XPalm),
        variants=Tuple(M.VariantSpec(arm) for arm in names),
        construct=(config, variant) -> Base.invokelatest(Batch._construct_batch, config, weather),
        prepare=(fixture, config, variant) -> Base.invokelatest(_prepare_batch, fixture, config, variant.name),
        lower=(simulations, fixture, config, variant) -> nothing,
        execute! = (simulations, program, fixture, config, variant) ->
            Base.invokelatest(Batch._execute_batch!, simulations, config),
        fingerprint=(simulations, fixture, config) -> Base.invokelatest(Batch._fingerprint_batch, simulations),
        coverage=(simulations, program, fixture, config, variant) -> Base.invokelatest(_coverage_batch, simulations, config, variant.name),
        work=(simulations, fixture, config) -> Base.invokelatest(Batch._work_batch, simulations, fixture, config))
end

function screen_xp_dispatch_refresh(spec; repetitions::Int=4, measure_retained=false)
    return Base.invokelatest(M.screen_case, spec; baseline=:ordinary_a, repetitions, measure_retained)
end

end # module
