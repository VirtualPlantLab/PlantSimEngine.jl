module NewbornBindingSequenceMeasurements

using PlantSimEngine, Test
const PSE = PlantSimEngine
const H = Main.DirectPlannerMeasurements
const F = Main.DirectPlannerFixtures
const M = Main.NativeDownstreamMeasurements
const CR = Main.CompiledRegionsExperiment
const NBM = Main.NewbornBindingMeasurements
const PB = Main.NativePBDriver
const XP = Main.NativeXPDriver
_base() = getfield(Main, :NewbornBindingProgram)
_sequence() = getfield(Main, :NewbornBindingSequence)

export SEQUENCE_ARMS, sequence_policies, prepare_sequence_arm,
    sequence_coverage, newborn_sequence_checks, register_newborn_sequence_case!

const SEQUENCE_ARMS = (:reference_executor, :binding_instructions,
    :binding_sequence, :bounded_preparation, :bounded_sequence)
const OPTIONAL_ARMS = (:typed_driver, :typed_sequence)
const ACTUAL_FIELDS = (:instruction_executions, :synthesized_bindings,
    :newborn_positive_executions, :initial_positive_executions,
    :existing_positive_executions, :producer_instruction_executions,
    :status_instruction_executions, :newborn_producer_executions,
    :newborn_status_executions, :newborn_targeted_executions,
    :newborn_global_refresh_executions)

function sequence_policies(arm::Symbol)
    arm in (SEQUENCE_ARMS..., OPTIONAL_ARMS...) ||
        throw(ArgumentError("Unknown newborn-sequence arm: $arm"))
    mechanism = arm in (:binding_sequence, :bounded_sequence, :typed_sequence) ?
        :sequence : arm === :binding_instructions ? :base : :ordinary
    bounded = arm in (:bounded_preparation, :bounded_sequence)
    typed = arm in OPTIONAL_ARMS
    underlying_arm = typed ? :selected_driver :
        bounded ? :bounded_preparation : :reference_executor
    return (; mechanism, bounded, typed, underlying_arm)
end

"""Enable independent sequence/base/bounded policies inside measured preparation.

No shared declaration/world cache is enabled. Base certificates and consumer
sequences are prepared on each fresh model, with all costs in normal PSE
preparation. Numerical kernels and canonical references remain ordinary.
"""
Base.@nospecializeinfer @noinline function prepare_sequence_arm(model, arm::Symbol;
    outputs=:none, performance=false, count_calls=false, details::Bool=false,
    constants=PSE.PlantMeteo.Constants())
    @nospecialize model outputs constants
    policy = sequence_policies(arm)
    if policy.mechanism === :sequence
        Base.invokelatest(_sequence().enable_newborn_binding_sequence!, model; details)
    elseif policy.mechanism === :base
        details && throw(ArgumentError("Sequence detail mode requires a sequence arm"))
        Base.invokelatest(_base().enable_newborn_binding_program!, model)
    else
        details && throw(ArgumentError("Sequence detail mode requires a sequence arm"))
    end
    return Base.invokelatest(H.prepare_arm, model, policy.underlying_arm;
        outputs, performance, count_calls, constants)
end

function _actual_counts(report)
    counts = report.counters
    return NamedTuple{ACTUAL_FIELDS}(Tuple(getproperty(counts, name) for name in ACTUAL_FIELDS))
end
function _validate_counts(report; details=true)
    counts = _actual_counts(report)
    all(value -> value isa Integer && value >= 0, values(counts)) ||
        error("Invalid actual instruction counters")
    counts.instruction_executions == counts.synthesized_bindings ||
        error("Instruction completions differ from constructed bindings")
    counts.initial_positive_executions + counts.existing_positive_executions +
        counts.newborn_positive_executions == counts.instruction_executions ||
        error("Initial/existing/newborn instruction partition is inconsistent")
    counts.producer_instruction_executions + counts.status_instruction_executions ==
        counts.instruction_executions || error("Producer/status instruction partition is inconsistent")
    counts.newborn_producer_executions + counts.newborn_status_executions ==
        counts.newborn_positive_executions || error("Newborn producer/status partition is inconsistent")
    counts.newborn_targeted_executions + counts.newborn_global_refresh_executions ==
        counts.newborn_positive_executions || error("Newborn phase partition is inconsistent")
    if details
        sum((row.executions for row in report.per_input); init=0) == counts.instruction_executions ||
            error("Detailed per-input counts differ from actual completions")
    else
        isempty(report.per_input) && isempty(report.misses) ||
            error("Sequence details were recorded while disabled")
    end
    return counts
end

"""Keep base-fallback and sequence work separate; sum completions exactly once.

A sequence candidate must execute its own newborn PRODUCER instructions for
XP/generic growth. Falling back entirely to the base hook cannot qualify it as
an optimized sequence. PB has no required binding eligibility and receives no
binding credit from its independent numerical-driver batch entries.
"""
Base.@nospecializeinfer @noinline function sequence_coverage(simulation,
    arm::Symbol, kind; instrumented=false, details::Bool=false,
    require_newborn=kind in (:xp, :generic))
    @nospecialize simulation
    policy = sequence_policies(arm)
    ordinary = Base.invokelatest(H.coverage, simulation, policy.underlying_arm, kind;
        instrumented)
    base = Base.invokelatest(_base().newborn_binding_program_report, simulation)
    sequence = Base.invokelatest(_sequence().newborn_binding_sequence_report, simulation)
    isequal(base, sequence.base_program) || error("Sequence/base certificate reports disagree")
    base_counts = _validate_counts(base)
    sequence_counts = _validate_counts(sequence; details=sequence.details_enabled)
    total = NamedTuple{ACTUAL_FIELDS}(Tuple(getproperty(base_counts, name) +
        getproperty(sequence_counts, name) for name in ACTUAL_FIELDS))
    if policy.mechanism === :ordinary
        !base.enabled && !sequence.enabled && all(iszero, values(total)) ||
            error("Instruction policies contaminated ordinary control")
    elseif policy.mechanism === :base
        base.enabled && !sequence.enabled && all(iszero, values(sequence_counts)) ||
            error("Base arm has missing policy or sequence contamination")
        if require_newborn
            base_counts.newborn_producer_executions > 0 ||
                error("Base arm executed no newborn producer instruction")
        end
    else
        base.enabled && sequence.enabled || error("Sequence/base preparation policy missing")
        sequence.details_enabled === details || error("Sequence detail mode differs from configured arm")
        if require_newborn
            sequence_counts.newborn_producer_executions > 0 ||
                error("Sequence arm executed no own newborn producer instruction")
            sequence.counters.consumer_program_executions > 0 ||
                error("Sequence arm entered no consumer program")
        end
    end
    if total.producer_instruction_executions > 0
        base.counters.declaration_proofs_built > 0 ||
            error("Producer instructions have no base declaration certificate")
    end
    return merge(ordinary, (sequence_arm=arm, sequence_policies=policy,
        base_program=base, sequence_program=sequence,
        base_actual=base_counts, sequence_actual=sequence_counts, total_actual=total,
        actual_newborn_producer_instructions=total.newborn_producer_executions,
        actual_sequence_newborn_producer_instructions=sequence_counts.newborn_producer_executions,
        sequence_details=details, metadata_work_is_not_kernel_work=true,
        measurement_protocol=:base_vs_consumer_sequence_v1,
        counter_accounting=:base_actual_plus_sequence_actual_once_not_embedded_base_twice,
        declaration_cache_scope=:fresh_model_program_state_no_shared_world_cache,
        optimization_scope=sequence_counts.newborn_producer_executions > 0 ?
            :actual_sequence_newborn_producer_operations :
            total.newborn_producer_executions > 0 ? :actual_base_newborn_producer_operations :
            :no_newborn_binding_optimization_credit))
end

"""Cheap source-cohort parity gate; diagnostics are outside performance timing."""
Base.@nospecializeinfer @noinline function newborn_sequence_checks(kind::Symbol=:xp;
    arm::Symbol=:binding_sequence, steps::Int=2, nobjects::Int=2,
    additions::Int=3, outputs=:all, details::Bool=false,
    require_newborn=kind in (:xp, :generic))
    kind in (:pb, :xp, :generic) || throw(ArgumentError("Expected :pb, :xp or :generic"))
    config = H.construct_config(kind; steps, nobjects, additions, outputs)
    reports = Dict{Symbol,Any}()
    @testset "Consumer sequence: original scientific and reference parity" begin
        left = Base.invokelatest(NBM._construct_binding_fixture, kind, config)
        right = Base.invokelatest(NBM._construct_binding_fixture, kind, config)
        control = Base.invokelatest(prepare_sequence_arm, left.model, :reference_executor; outputs)
        candidate = Base.invokelatest(prepare_sequence_arm, right.model, arm;
            outputs, details, count_calls=true)
        before_left = Base.invokelatest(F.identities, left.model)
        before_right = Base.invokelatest(F.identities, right.model)
        @test keys(before_left.statuses) == keys(before_right.statuses)
        @test keys(before_left.references) == keys(before_right.references)
        @test all(key -> before_left.references[key] !== before_right.references[key], keys(before_left.references))
        @test isequal(Base.invokelatest(F.snapshot, candidate, kind),
            Base.invokelatest(F.snapshot, control, kind))
        for _ in 1:steps
            Base.invokelatest(PSE.step!, control)
            Base.invokelatest(PSE.step!, candidate)
            @test isequal(Base.invokelatest(F.snapshot, candidate, kind),
                Base.invokelatest(F.snapshot, control, kind))
            @test Base.invokelatest(F.scientific_rngs, left.model) ==
                Base.invokelatest(F.scientific_rngs, right.model)
            current_left = Base.invokelatest(F.identities, left.model)
            current_right = Base.invokelatest(F.identities, right.model)
            @test F.same_identity_transitions(before_left, before_right,
                current_left, current_right)
            before_left, before_right = current_left, current_right
        end
        reports[:work] = Base.invokelatest(CR.downstream_work_report, candidate, right.initial_ids)
        @test reports[:work] == Base.invokelatest(CR.downstream_work_report, control, left.initial_ids)
        require_newborn && (@test !isempty(reports[:work].added_ids))
        reports[:ordinary] = Base.invokelatest(sequence_coverage, control,
            :reference_executor, kind; require_newborn=false)
        reports[:candidate] = Base.invokelatest(sequence_coverage, candidate, arm, kind;
            details, require_newborn)
    end
    return reports
end

"""Register balanced independent base/sequence/bounded comparisons, no execution.

Details are deliberately false in this timing cohort. Fixed actual counters
remain enabled. Forcing is read at registration and copied per fresh scenario;
science/state/history/types/topology/RNG/work checks run after timing.
"""
Base.@nospecializeinfer @noinline function register_newborn_sequence_case!(
    name::Symbol, kind::Symbol; steps::Int=kind === :xp ? 4 : 2,
    nobjects::Int=2, additions::Int=3, arms=SEQUENCE_ARMS, outputs=:none,
    seed::Int=1, emission_speed::Real=0.2, replace::Bool=false,
    require_newborn=kind in (:xp, :generic))
    kind in (:pb, :xp, :generic) || throw(ArgumentError("Expected :pb, :xp or :generic"))
    steps > 0 && nobjects > 0 && additions >= 0 || error("Invalid fixture dimensions")
    names = Tuple(Symbol(arm) for arm in arms)
    :reference_executor in names || error("Include the same-source ordinary control")
    length(unique(names)) == length(names) || error("Duplicate comparison arm")
    config = merge(H.construct_config(kind; steps, nobjects, additions, seed,
        emission_speed, outputs),
        (sequence_policies_by_arm=Dict(arm => sequence_policies(arm) for arm in names),
         mechanism=:base_vs_consumer_sequence_cross_bounded_preparation,
         measurement_protocol=:base_vs_consumer_sequence_v1,
         sequence_details=false, shared_world_cache=false,
         require_actual_newborn_instruction=require_newborn,
         forcing_setup=:read_at_registration_copied_inside_each_fresh_sample))
    weather = kind === :xp ? CR._xpalm_fixture_weather(steps) : nothing
    return M.register_case!(name; config, replace, packages=(PSE, PB.PB, XP.XPalm),
        variants=Tuple(M.VariantSpec(arm) for arm in names),
        construct=(config, variant) -> Base.invokelatest(NBM._construct_binding_fixture,
            kind, config; weather),
        prepare=(fixture, config, variant) -> Base.invokelatest(prepare_sequence_arm,
            fixture.model, variant.name; outputs=config.outputs, details=false),
        lower=(simulation, fixture, config, variant) -> nothing,
        execute! = (simulation, program, fixture, config, variant) ->
            Base.invokelatest(PSE.continue!, simulation; steps=config.steps),
        fingerprint=(simulation, fixture, config) -> (
            state=Base.invokelatest(F.snapshot, simulation, kind),
            scientific_rngs=Base.invokelatest(F.scientific_rngs, simulation.model)),
        coverage=(simulation, program, fixture, config, variant) ->
            Base.invokelatest(sequence_coverage, simulation, variant.name, kind;
                details=false, require_newborn=config.require_actual_newborn_instruction),
        work=(simulation, fixture, config) ->
            Base.invokelatest(CR.downstream_work_report, simulation, fixture.initial_ids))
end

end # module
