module NewbornBindingMeasurements

# Diagnostics and fresh-case registration only. Root executes Julia via Kaimon.
using Dates, PlantSimEngine, Test
const PSE = PlantSimEngine
const H = Main.DirectPlannerMeasurements
const F = Main.DirectPlannerFixtures
const M = Main.NativeDownstreamMeasurements
const CR = Main.CompiledRegionsExperiment
const PB = Main.NativePBDriver
const XP = Main.NativeXPDriver

export BINDING_ARMS, binding_policies, prepare_binding_arm, binding_coverage,
    binding_plan_inventory, register_newborn_binding_case!, newborn_binding_checks

const BINDING_ARMS = (:reference_executor, :binding_instructions,
    :bounded_preparation, :bounded_instructions)
const OPTIONAL_ARMS = (:typed_driver, :typed_instructions,
    :bounded_typed, :bounded_typed_instructions)
_program() = getfield(Main, :NewbornBindingProgram)

PSE.@process "newborn_binding_scalar_consumer" verbose=false
struct ScalarConsumer{T} <: AbstractNewborn_Binding_Scalar_ConsumerModel
    initial::T
end
PSE.inputs_(::ScalarConsumer{T}) where {T} = (signal=PSE.Required(T),)
PSE.outputs_(model::ScalarConsumer) = (received=model.initial, consumer_visits=0)
function PSE.run!(::ScalarConsumer, status, environment, constants, context)
    status.received += status.signal
    status.consumer_visits += 1
    return nothing
end

# Keep the old DP fixture frozen. Reuse its existing creator/source/Many
# collector and add one real generic scalar input per growing unit here.
Base.@nospecializeinfer @noinline function _construct_binding_fixture(
    kind::Symbol, config; weather=nothing)
    @nospecialize config weather
    kind === :generic || return Base.invokelatest(F.construct_fixture, kind, config; weather)
    nobjects = config.nobjects
    model = PSE.CompositeModel(PSE.Object(0),
        (F._unit(id) for id in 1:nobjects)...;
        applications=(
            PSE.ModelSpec(F.GrowthPulse(config.additions, nobjects+1); name=:create,
                on=PSE.One(id=0), every=Hour(1)),
            PSE.ModelSpec(F.GrowthSource(); name=:source,
                on=PSE.Many(kind=:direct_growth_unit), every=Hour(1)),
            PSE.ModelSpec(F.GrowthCollect(); name=:collect,
                on=PSE.One(id=0), every=Hour(1),
                inputs=(signals=PSE.Many(kind=:direct_growth_unit,
                    within=PSE.SceneScope(), application=:source, var=:signal),)),
            PSE.ModelSpec(ScalarConsumer(0.0f0); name=:scalar_consumer,
                on=PSE.Many(kind=:direct_growth_unit), every=Hour(1),
                inputs=(signal=PSE.One(within=PSE.Self(), application=:source,
                    var=:signal),)),
        ), environment=(duration=Hour(1),))
    return (; model, initial_ids=collect(PSE.object_ids(model)), package=:generic)
end

function binding_policies(arm::Symbol)
    arm in (BINDING_ARMS..., OPTIONAL_ARMS...) ||
        throw(ArgumentError("Unknown newborn-binding arm: $arm"))
    bounded = arm in (:bounded_preparation, :bounded_instructions,
        :bounded_typed, :bounded_typed_instructions)
    typed = arm in OPTIONAL_ARMS
    instructions = arm in (:binding_instructions, :bounded_instructions,
        :typed_instructions, :bounded_typed_instructions)
    underlying_arm = typed ? (bounded ? :bounded_selected : :selected_driver) :
        bounded ? :bounded_preparation : :reference_executor
    return (; instructions, bounded, typed, underlying_arm)
end

"""Enable reusable binding instructions inside normal measured preparation.

Uses the original numerical models, canonical reference storage and standard
Simulation lifecycle. Instructions and bounded metadata are independent flags.
No old partition/heap experiment or future-layout catalogue is enabled.
"""
Base.@nospecializeinfer @noinline function prepare_binding_arm(model, arm::Symbol;
    outputs=:none, performance=false, count_calls=false,
    constants=PSE.PlantMeteo.Constants())
    @nospecialize model outputs constants
    policy = binding_policies(arm)
    policy.instructions && Base.invokelatest(
        _program().enable_newborn_binding_program!, model)
    return Base.invokelatest(H.prepare_arm, model, policy.underlying_arm;
        outputs, performance, count_calls, constants)
end

"""Actual metadata-operation coverage, separate from numerical driver work.

The XP and scalar-coupled generic growth fixtures must execute instructions for
consumers added in the current lifecycle event. PB may have no eligible instruction; that is
explicitly reported and receives no optimization credit. A prepared instruction
or nonempty model does not prove execution.
"""
Base.@nospecializeinfer @noinline function binding_coverage(simulation,
    arm::Symbol, kind; instrumented=false, require_newborn=kind in (:xp, :generic))
    @nospecialize simulation
    policy = binding_policies(arm)
    base = Base.invokelatest(H.coverage, simulation, policy.underlying_arm, kind;
        instrumented)
    report = Base.invokelatest(_program().newborn_binding_program_report, simulation)
    counters = report.counters
    has_producer_counter = hasproperty(counters, :newborn_producer_executions)
    newborn_producers = has_producer_counter ? counters.newborn_producer_executions : nothing
    if policy.instructions
        report.enabled || error("Binding instruction policy was not enabled")
        if require_newborn
            counters.instruction_executions > 0 ||
                error("Instruction candidate executed no binding instruction")
            counters.newborn_positive_executions > 0 ||
                error("Instruction candidate executed no instruction for a newborn consumer")
            if has_producer_counter
                newborn_producers > 0 ||
                    error("Instruction candidate executed no producer-bound instruction for a newborn consumer")
            end
        end
    else
        report.enabled && error("Binding instructions contaminated ordinary control")
        iszero(counters.instruction_executions) &&
            iszero(counters.newborn_positive_executions) ||
            error("Disabled instruction policy has execution work")
        has_producer_counter && !iszero(newborn_producers) &&
            error("Disabled instruction policy has newborn producer work")
    end
    qualification = !policy.instructions ? :ordinary_bindings :
        counters.newborn_positive_executions > 0 ? :actual_newborn_binding_instruction :
        counters.instruction_executions > 0 ? :actual_binding_instruction :
        :enabled_without_eligible_instruction_execution
    return merge(base, (binding_arm=arm, binding_policies=policy,
        binding_program=report, binding_qualification=qualification,
        actual_binding_instructions=counters.instruction_executions,
        actual_newborn_binding_instructions=counters.newborn_positive_executions,
        actual_newborn_producer_instructions=newborn_producers,
        newborn_producer_coverage=has_producer_counter ? :actual_completion_counter :
            :unavailable_total_newborn_and_per_input_counts_reported_separately,
        metadata_work_is_not_kernel_work=true,
        qualification_scope=:actual_instruction_completions_and_separate_numerical_batch_entries))
end

_count!(counts, key) = (counts[key] = get(counts, key, 0) + 1)

function _owners(compiled, id, variable)
    distributed = compiled.distributed_outputs
    distributed isa PSE.NoCompiledDistributedOutputs && return ()
    return get(distributed.writer_ownership, (id, variable), ())
end

function _cadence(application)
    clock = application.clock
    return (dt=clock.dt, phase=clock.phase,
        authored_timestep=repr(application.timestep))
end

"""Post-execution inventory of actual input plans and bindings.

No scientific kernel, environment sampling, selector resolution, IR or status
value read is performed. Counts describe current live bindings, not optimized
instruction entries. Call outside all timing phases. `initial_ids` partitions
actual consumers into existing and born objects without treating initial
targetless plans as executed work.
"""
Base.@nospecializeinfer @noinline function binding_plan_inventory(simulation;
    initial_ids=())
    @nospecialize simulation initial_ids
    compiled = simulation.compiled
    model = simulation.model
    initial = Set(initial_ids)
    plans = Any[]
    bindings_by_slot = Dict{Int,Vector{Any}}()
    for binding in compiled.input_bindings
        push!(get!(bindings_by_slot, binding.plan.slot, Any[]), binding)
    end
    totals = Dict{Symbol,Int}()
    for plan in compiled.scenario_plan.input_plans
        counts = Dict{Symbol,Int}()
        policies = Dict{String,Int}()
        hints = Dict{Symbol,Int}()
        source_applications = Set{Symbol}()
        consumer_scales = Dict{String,Int}()
        for binding in get(bindings_by_slot, plan.slot, Any[])
            _count!(counts, :bindings)
            cohort = isempty(initial) ? :unclassified_bindings :
                binding.consumer_id in initial ? :existing_bindings : :newborn_bindings
            _count!(counts, cohort)
            consumer = PSE.model_object(model, binding.consumer_id)
            _count!(consumer_scales, string(consumer.scale))
            _count!(policies, string(nameof(typeof(binding.policy))))
            _count!(hints, binding.carrier_hint)
            union!(source_applications, binding.source_application_ids)
            isempty(binding.source_ids) && _count!(counts, :empty_membership)
            for source_id in binding.source_ids
                owners = _owners(compiled, source_id, plan.source_var)
                local_count = count(owner -> owner.kind === :application_target, owners)
                distributed_count = count(owner -> owner.kind === :output_destination, owners)
                _count!(counts, :source_members)
                _count!(counts, iszero(distributed_count) ?
                    :sources_without_distributed_owners : :sources_with_distributed_owners)
                local_count > 1 && _count!(counts, :sources_with_multiple_local_owners)
                length(owners) > 1 && _count!(counts, :sources_with_multiple_owners)
            end
        end
        for (key, value) in counts
            totals[key] = get(totals, key, 0) + value
        end
        producers = [(application=id,
            cadence=_cadence(compiled.applications_by_id[id]))
            for id in sort!(collect(source_applications))]
        push!(plans, (slot=plan.slot, application=plan.application_id,
            input=plan.input, origin=plan.origin, multiplicity=plan.multiplicity,
            source_variable=plan.source_var, requested_application=plan.application,
            requested_process=plan.process,
            potential_applications=collect(plan.potential_source_application_ids),
            potential_source_count=length(plan.potential_source_application_ids),
            from_status=PSE._selector_from_status(plan.selector),
            explicit_policy=PSE._selector_has_policy(plan.selector),
            consumer_cadence=_cadence(compiled.applications_by_id[plan.application_id]),
            actual_source_applications=producers, counts, policies, carrier_hints=hints,
            consumer_scales))
    end
    return (scope=:post_execution_current_live_bindings,
        inference=:inventory_not_optimized_coverage,
        initial_ids_supplied=!isempty(initial), plan_count=length(plans),
        binding_count=length(compiled.input_bindings), totals, plans)
end

"""Independent full-history scientific and canonical-reference parity gate.

Run this in a correctness worker before warm timings; it intentionally takes
snapshots and inventories. It does not establish cold compilation performance.
"""
Base.@nospecializeinfer @noinline function newborn_binding_checks(kind::Symbol=:xp;
    arm::Symbol=:binding_instructions, steps::Int=2, nobjects::Int=2,
    additions::Int=3, outputs=:all, require_newborn=kind in (:xp, :generic))
    kind in (:pb, :xp, :generic) || throw(ArgumentError("Expected :pb, :xp or :generic"))
    steps > 0 && nobjects > 0 && additions >= 0 || error("Invalid fixture dimensions")
    reports = Dict{Symbol,Any}()
    @testset "Reusable binding instructions: fresh scientific parity" begin
        config = H.construct_config(kind; steps, nobjects, additions, outputs)
        left = Base.invokelatest(_construct_binding_fixture, kind, config)
        right = Base.invokelatest(_construct_binding_fixture, kind, config)
        control = Base.invokelatest(prepare_binding_arm, left.model, :reference_executor;
            outputs, count_calls=true)
        candidate = Base.invokelatest(prepare_binding_arm, right.model, arm;
            outputs, count_calls=true)
        old_left = Base.invokelatest(F.identities, left.model)
        old_right = Base.invokelatest(F.identities, right.model)
        @test keys(old_left.statuses) == keys(old_right.statuses)
        @test keys(old_left.references) == keys(old_right.references)
        @test all(key -> old_left.statuses[key] !== old_right.statuses[key], keys(old_left.statuses))
        @test all(key -> old_left.references[key] !== old_right.references[key], keys(old_left.references))
        @test isequal(Base.invokelatest(F.snapshot, candidate, kind),
            Base.invokelatest(F.snapshot, control, kind))
        @test Base.invokelatest(F.scientific_rngs, right.model) ==
            Base.invokelatest(F.scientific_rngs, left.model)
        for _ in 1:steps
            Base.invokelatest(PSE.step!, control)
            Base.invokelatest(PSE.step!, candidate)
            @test isequal(Base.invokelatest(F.snapshot, candidate, kind),
                Base.invokelatest(F.snapshot, control, kind))
            @test Base.invokelatest(F.scientific_rngs, right.model) ==
                Base.invokelatest(F.scientific_rngs, left.model)
            current_left = Base.invokelatest(F.identities, left.model)
            current_right = Base.invokelatest(F.identities, right.model)
            @test F.same_identity_transitions(old_left, old_right,
                current_left, current_right)
            old_left, old_right = current_left, current_right
        end
        expected_work = Base.invokelatest(CR.downstream_work_report, control, left.initial_ids)
        actual_work = Base.invokelatest(CR.downstream_work_report, candidate, right.initial_ids)
        @test actual_work == expected_work
        require_newborn && (@test !isempty(actual_work.added_ids))
        reports[:ordinary] = Base.invokelatest(binding_coverage, control,
            :reference_executor, kind; require_newborn=false)
        reports[:candidate] = Base.invokelatest(binding_coverage, candidate, arm, kind;
            require_newborn)
        reports[:work] = actual_work
        reports[:inventory] = Base.invokelatest(binding_plan_inventory, candidate;
            initial_ids=right.initial_ids)
    end
    return reports
end

"""Register balanced fresh-scenario comparisons without running science.

`M.screen_case` supplies alternating forward/reverse order, full post-execution
state/history/topology/numeric-type/model-RNG fingerprints and equal work. XP
forcing is read once here and copied into each independently constructed scene.
Enablement, normal preparation and any typed-driver construction remain in
complete cost. Coverage does not sample environments or reuse scientific data.
"""
Base.@nospecializeinfer @noinline function register_newborn_binding_case!(
    name::Symbol, kind::Symbol; steps::Int=kind === :xp ? 4 : 2,
    nobjects::Int=2, additions::Int=3, arms=BINDING_ARMS, outputs=:none,
    seed::Int=1, emission_speed::Real=0.2, replace::Bool=false,
    require_newborn=kind in (:xp, :generic))
    kind in (:pb, :xp, :generic) || throw(ArgumentError("Expected :pb, :xp or :generic"))
    steps > 0 && nobjects > 0 && additions >= 0 || error("Invalid fixture dimensions")
    names = Tuple(Symbol(arm) for arm in arms)
    :reference_executor in names || error("Include the same-source ordinary control")
    length(unique(names)) == length(names) || error("Duplicate comparison arm")
    config = merge(H.construct_config(kind; steps, nobjects, additions, seed,
        emission_speed, outputs),
        (binding_policies_by_arm=Dict(arm => binding_policies(arm) for arm in names),
         mechanism=:reusable_binding_instructions_cross_bounded_preparation,
         require_actual_newborn_instruction=require_newborn,
         forcing_setup=:read_at_registration_copied_inside_each_fresh_sample))
    weather = kind === :xp ? CR._xpalm_fixture_weather(steps) : nothing
    return M.register_case!(name; config, replace, packages=(PSE, PB.PB, XP.XPalm),
        variants=Tuple(M.VariantSpec(arm) for arm in names),
        construct=(config, variant) -> Base.invokelatest(_construct_binding_fixture, kind, config; weather),
        prepare=(fixture, config, variant) -> Base.invokelatest(prepare_binding_arm,
            fixture.model, variant.name; outputs=config.outputs),
        lower=(simulation, fixture, config, variant) -> nothing,
        execute! = (simulation, program, fixture, config, variant) ->
            Base.invokelatest(PSE.continue!, simulation; steps=config.steps),
        fingerprint=(simulation, fixture, config) -> (
            state=Base.invokelatest(F.snapshot, simulation, kind),
            scientific_rngs=Base.invokelatest(F.scientific_rngs, simulation.model)),
        coverage=(simulation, program, fixture, config, variant) ->
            Base.invokelatest(binding_coverage, simulation, variant.name, kind;
                require_newborn=config.require_actual_newborn_instruction),
        work=(simulation, fixture, config) ->
            Base.invokelatest(CR.downstream_work_report, simulation, fixture.initial_ids))
end

end # module
