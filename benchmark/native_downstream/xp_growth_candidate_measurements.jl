module XPGrowthCandidateMeasurements

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
_lookup() = getfield(Main, :ExecutionGroupEpochLookup)

export CANDIDATE_ARMS, candidate_policies, prepare_candidate,
    candidate_coverage, candidate_checks, register_xp_candidate_batch_case!,
    screen_xp_candidate_batch

const CANDIDATE_ARMS = (:bounded_a, :bounded_b, :bounded_sequence, :graph_only, :lookup_only,
    :graph_lookup, :graph_lookup_sequence)

function candidate_policies(arm::Symbol)
    arm in CANDIDATE_ARMS || throw(ArgumentError("Unknown XP candidate arm: $arm"))
    graph = arm in (:graph_only, :graph_lookup, :graph_lookup_sequence)
    lookup = arm in (:lookup_only, :graph_lookup, :graph_lookup_sequence)
    sequence = arm in (:bounded_sequence, :graph_lookup_sequence)
    return (; graph, lookup, sequence, bounded=true,
        underlying_arm=sequence ? :bounded_sequence : :bounded_preparation)
end

"""Enable independent graph/lookup policies inside measured normal preparation."""
Base.@nospecializeinfer @noinline function prepare_candidate(model, arm::Symbol;
    outputs=:none, performance=false, count_calls=false)
    @nospecialize model outputs
    policy = candidate_policies(arm)
    policy.graph && Base.invokelatest(_graph().enable_graph_row_projection!, model)
    policy.lookup && Base.invokelatest(_lookup().enable_execution_group_epoch_lookup!, model)
    return Base.invokelatest(NSM.prepare_sequence_arm, model, policy.underlying_arm;
        outputs, performance, count_calls, details=false)
end

function _lookup_counts(report)
    c, e = report.v1.counters, report.counters
    e.epoch_attempts == e.epochs_validated + e.epochs_rejected ||
        error("Epoch validation totals disagree")
    c.lookups == c.slot_hits + c.slot_misses + e.trusted_empty_returns ||
        error("Lookup hit/miss/trusted-empty totals disagree")
    c.slot_misses == c.absent_slot_misses + c.out_of_range_misses + c.identity_misses ||
        error("Lookup miss-reason totals disagree")
    c.dictionary_lookups == c.slot_misses || error("Original-ID fallback count differs from misses")
    0 <= c.dictionaries_built <= c.refresh_lookups_created ||
        error("More fallback dictionaries than refresh lookup objects")
    report.dictionary_builds_avoided == c.refresh_lookups_created - c.dictionaries_built ||
        error("Avoided dictionary-build count is inconsistent")
    e.nonempty_epoch_hits <= c.slot_hits || error("Epoch hits exceed actual slot hits")
    e.query_fallbacks == c.slot_misses || error("Epoch fallback queries differ from ID fallbacks")
    return c
end

"""Require executed graph-table completion and growth slot hits, not attempts.

PB's static feature check may legitimately have no runtime lookup work; it is
reported without eligibility credit. Numerical batches and NBS base/sequence
namespaces remain separate from graph and previous-group lookup operations.
"""
Base.@nospecializeinfer @noinline function candidate_coverage(simulation,
    arm::Symbol, kind; require_lookup=kind === :xp, instrumented=false)
    @nospecialize simulation
    policy = candidate_policies(arm)
    underlying = Base.invokelatest(NSM.sequence_coverage, simulation,
        policy.underlying_arm, kind; details=false, instrumented,
        require_newborn=kind === :xp)
    graph = Base.invokelatest(_graph().graph_row_projection_report, simulation)
    lookup = Base.invokelatest(_lookup().execution_group_epoch_lookup_report, simulation)
    g, l, e = graph.counters, _lookup_counts(lookup), lookup.counters
    if policy.graph
        graph.enabled && g.projections_completed > 0 && g.rows_projected > 0 ||
            error("Graph candidate completed no actual projected graph table")
    else
        !graph.enabled && iszero(g.projections_completed) && iszero(g.rows_projected) &&
            iszero(g.edges_projected) || error("Graph projection contaminated control")
    end
    if policy.lookup
        lookup.enabled && lookup.v1.enabled || error("Previous-group epoch lookup policy missing")
        if require_lookup
            l.refresh_lookups_created > 0 && l.slot_hits > 0 &&
                e.epochs_validated > 0 && e.nonempty_epoch_hits > 0 ||
                error("Lookup candidate executed no epoch-validated nonempty growth hit")
        end
    else
        !lookup.enabled && !lookup.v1.enabled && all(iszero, values(l)) &&
            all(iszero, values(e)) ||
            error("Previous-group lookup contaminated control")
    end
    return merge(underlying, (candidate_arm=arm, candidate_policies=policy,
        graph_projection=graph, execution_group_lookup=lookup,
        actual_graph_completions=g.projections_completed,
        actual_graph_rows=g.rows_projected, actual_graph_edges=g.edges_projected,
        actual_lookup_slot_hits=l.slot_hits, actual_lookup_fallback_builds=l.dictionaries_built,
        actual_lookup_epoch_hits=e.nonempty_epoch_hits,
        actual_lookup_trusted_empty=e.trusted_empty_returns,
        lookup_eligibility=e.epochs_validated > 0 && e.nonempty_epoch_hits > 0 ?
            :actual_epoch_validated_growth_hits : :no_epoch_runtime_hit_credit,
        measurement_protocol=:xp_graph_lookup_candidates_v2,
        metadata_work_is_not_kernel_work=true))
end

Base.@nospecializeinfer @noinline function _prepare_batch(fixture, config, arm)
    @nospecialize fixture config
    simulations = Any[]
    for instance in fixture.instances
        push!(simulations, Base.invokelatest(prepare_candidate, instance.model, arm;
            outputs=config.outputs))
    end
    return simulations
end

Base.@nospecializeinfer @noinline function _coverage_batch(simulations, config, arm)
    @nospecialize simulations config
    reports = Any[]
    for simulation in simulations
        push!(reports, Base.invokelatest(candidate_coverage, simulation, arm, :xp))
    end
    fields = NSM.ACTUAL_FIELDS
    total = NamedTuple{fields}(Tuple(sum(getproperty(row.total_actual, field)
        for row in reports) for field in fields))
    sequence = NamedTuple{fields}(Tuple(sum(getproperty(row.sequence_actual, field)
        for row in reports) for field in fields))
    lookup_fields = fieldnames(typeof(first(reports).execution_group_lookup.v1.counters))
    lookup = NamedTuple{lookup_fields}(Tuple(sum(getproperty(row.execution_group_lookup.v1.counters, field)
        for row in reports) for field in lookup_fields))
    epoch_fields = fieldnames(typeof(first(reports).execution_group_lookup.counters))
    epoch = NamedTuple{epoch_fields}(Tuple(sum(getproperty(row.execution_group_lookup.counters, field)
        for row in reports) for field in epoch_fields))
    graph = (projections_completed=sum(row.actual_graph_completions for row in reports),
        rows_projected=sum(row.actual_graph_rows for row in reports),
        edges_projected=sum(row.actual_graph_edges for row in reports))
    return (native_fields=sum(row.native_fields for row in reports),
        driver_units=sum(row.driver_units for row in reports),
        native_driver_units=sum(row.native_driver_units for row in reports),
        candidate_arm=arm, candidate_policies=candidate_policies(arm),
        per_instance=reports, actual_graph=graph, actual_lookup=lookup, actual_epoch_lookup=epoch,
        actual_completions=total, actual_sequence_completions=sequence,
        independent_instances=Base.invokelatest(Batch._independent_instances, simulations),
        counter_accounting=:sum_each_actual_namespace_per_instance_once,
        metadata_work_is_not_kernel_work=true,
        measurement_protocol=:xp_graph_lookup_candidates_v2,
        statistical_unit=:one_batch_sample,
        placebo_control=arm in (:bounded_a, :bounded_b))
end

"""Two-day original XP/PB full-state/history/RNG/reference parity before timing."""
Base.@nospecializeinfer @noinline function candidate_checks(kind::Symbol=:xp;
    arm::Symbol=:graph_lookup_sequence, steps::Int=2, nobjects::Int=2, outputs=:all)
    kind in (:xp, :pb) || throw(ArgumentError("Expected original :xp or :pb fixture"))
    steps > 0 && nobjects > 0 || error("Positive fixture dimensions required")
    config = H.construct_config(kind; steps, nobjects, outputs)
    report = Dict{Symbol,Any}()
    @testset "Graph and previous-group lookup retain original scientific features" begin
        left = Base.invokelatest(NBM._construct_binding_fixture, kind, config)
        right = Base.invokelatest(NBM._construct_binding_fixture, kind, config)
        control = Base.invokelatest(prepare_candidate, left.model, :bounded_a;
            outputs, count_calls=true)
        candidate = Base.invokelatest(prepare_candidate, right.model, arm;
            outputs, count_calls=true)
        before_left = Base.invokelatest(F.identities, left.model)
        before_right = Base.invokelatest(F.identities, right.model)
        @test keys(before_left.references) == keys(before_right.references)
        @test all(key -> before_left.references[key] !== before_right.references[key], keys(before_left.references))
        @test isequal(Base.invokelatest(F.snapshot, control, kind), Base.invokelatest(F.snapshot, candidate, kind))
        @test Base.invokelatest(F.scientific_rngs, left.model) == Base.invokelatest(F.scientific_rngs, right.model)
        for _ in 1:steps
            Base.invokelatest(PSE.step!, control)
            Base.invokelatest(PSE.step!, candidate)
            @test isequal(Base.invokelatest(F.snapshot, control, kind), Base.invokelatest(F.snapshot, candidate, kind))
            @test Base.invokelatest(F.scientific_rngs, left.model) == Base.invokelatest(F.scientific_rngs, right.model)
            after_left = Base.invokelatest(F.identities, left.model)
            after_right = Base.invokelatest(F.identities, right.model)
            @test F.same_identity_transitions(before_left, before_right, after_left, after_right)
            before_left, before_right = after_left, after_right
        end
        work = Base.invokelatest(CR.downstream_work_report, candidate, right.initial_ids)
        @test work == Base.invokelatest(CR.downstream_work_report, control, left.initial_ids)
        report[:work] = work
        report[:ordinary] = Base.invokelatest(candidate_coverage, control, :bounded_a, kind)
        report[:candidate] = Base.invokelatest(candidate_coverage, candidate, arm, kind)
    end
    return report
end

"""Same-source independent/combined candidates with identical A/A controls.

All flags are enabled inside preparation; all original XP models/statuses,
forcing and lifecycle remain ordinary. Construction and preparation for every
independent instance stay in complete cost. Batched execution only reduces
timer granularity. Per-instance observations, work and counts are checked after
timing through the frozen prepared-batch utilities.
"""
Base.@nospecializeinfer @noinline function register_xp_candidate_batch_case!(
    name::Symbol=:xp_growth_candidates; batch_size::Int=2, steps::Int=2,
    arms=CANDIDATE_ARMS, outputs=:none, seed::Int=1,
    emission_speed::Real=0.2, replace::Bool=false)
    batch_size > 0 && steps > 0 || error("Positive batch dimensions required")
    names = Tuple(Symbol(arm) for arm in arms)
    :bounded_a in names && :bounded_b in names && length(unique(names)) == length(names) ||
        error("Include both A/A bounded controls exactly once")
    config = merge(H.construct_config(:xp; steps, nobjects=2, additions=3,
        seed, emission_speed, outputs), (;
        batch_size, candidate_policies_by_arm=Dict(arm => candidate_policies(arm) for arm in names),
        measurement_protocol=:xp_graph_lookup_candidates_v2,
        lookup_policy=:complete_previous_index_epoch_and_lazy_original_ID_fallback,
        statistical_unit=:one_batch_sample,
        execution_scope=:advance_each_independent_prepared_simulation_once,
        complete_cost_scope=:construction_enablement_all_preparation_and_batch_execution,
        per_simulation_normalization=:divide_reported_batch_phase_by_batch_size,
        placebo_pair=(:bounded_a, :bounded_b), sequence_details=false,
        shared_world_cache=false,
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
        coverage=(simulations, program, fixture, config, variant) ->
            Base.invokelatest(_coverage_batch, simulations, config, variant.name),
        work=(simulations, fixture, config) -> Base.invokelatest(Batch._work_batch, simulations, fixture, config))
end

function screen_xp_candidate_batch(spec; repetitions::Int=4, measure_retained=false)
    return Base.invokelatest(M.screen_case, spec; baseline=:bounded_a,
        repetitions, measure_retained)
end

end # module
