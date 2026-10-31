module NewbornBindingProgramChecks

using Dates, Random, Test, PlantSimEngine
const PSE = PlantSimEngine
export newborn_binding_generic_checks, newborn_binding_guard_checks,
    newborn_binding_feature_checks, newborn_binding_recompile_checks,
    newborn_binding_downstream_checks, newborn_binding_declaration_checks,
    newborn_binding_header_checks

_C() = getfield(Main, :GrowthInputReuseChecks)
_F() = getfield(Main, :DirectPlannerFixtures)
_program() = getfield(Main, :NewbornBindingProgram)
_enable!(model) = Base.invokelatest(_program().enable_newborn_binding_program!, model)
_report(value) = Base.invokelatest(_program().newborn_binding_program_report, value)

function _binding_shape(simulation)
    return [(_C()._binding_description(binding), typeof(binding.policy),
        repr(binding.policy)) for binding in simulation.compiled.input_bindings]
end
function _state(reference, candidate, previous; kind=:generic)
    current = _C()._pair_state(reference, candidate, previous; kind)
    @test isequal(_binding_shape(candidate), _binding_shape(reference))
    _C()._live_bindings(reference)
    _C()._live_bindings(candidate)
    return current
end

# Actual implementation counter names are checked here, never synthesized from
# partition hits, empty consumers, logical plan count or expected object count.
_executions(report) = report.counters.instruction_executions
function _evidence(simulation; before=nothing, require_execution=false)
    report = _report(simulation)
    @test report.enabled
    delta = before === nothing ? nothing : _executions(report) - _executions(before)
    newborn_delta = before === nothing ? nothing :
        report.counters.newborn_positive_executions - before.counters.newborn_positive_executions
    bindings_delta = before === nothing ? nothing :
        report.counters.synthesized_bindings - before.counters.synthesized_bindings
    fallback_delta = before === nothing ? nothing :
        report.counters.resolved_fallbacks - before.counters.resolved_fallbacks
    if require_execution
        @test delta !== nothing && delta > 0
        @test newborn_delta !== nothing && newborn_delta > 0
        @test bindings_delta !== nothing && bindings_delta > 0
    end
    return (; report, new_instruction_executions=delta, newborn_delta, bindings_delta, fallback_delta,
        interpretation=:actual_binding_instruction_executions_not_partition_or_empty_hits)
end

PSE.@process "newborn_instruction_rng_source" verbose=false
PSE.@process "newborn_instruction_writer" verbose=false
struct RNGSource{R} <: AbstractNewborn_Instruction_Rng_SourceModel
    rng::R
end
PSE.inputs_(::RNGSource) = NamedTuple()
PSE.outputs_(::RNGSource) = (signal=0.0f0, visits=0)
function PSE.run!(model::RNGSource, status, environment, constants, context)
    status.signal += rand(model.rng, Float32)
    status.visits += 1
    return nothing
end
struct Writer <: AbstractNewborn_Instruction_WriterModel
    value::Float32
end
PSE.inputs_(::Writer) = NamedTuple()
PSE.outputs_(::Writer) = (signal=0.0f0,)
function PSE.run!(model::Writer, status, environment, constants, context)
    status.signal = model.value
    return nothing
end
function _rng_fixture(count)
    C = _C()
    specifications = C._generic_fixture(count).applications
    return PSE.CompositeModel(PSE.Object(:left; kind=:growth_input_gatherer),
        PSE.Object(:right; kind=:growth_input_gatherer), (C._unit(id) for id in 1:count)...;
        applications=(PSE.ModelSpec(RNGSource(MersenneTwister(17)); name=:source,
            on=PSE.Many(kind=:growth_input_unit), every=Hour(1)), specifications[2:end]...),
        environment=(duration=Hour(1),))
end

"""Float32/RNG, One/OptionalOne/Many, new consumers, and escaped canonical refs."""
function newborn_binding_generic_checks(; outputs=:all)
    C, F = _C(), _F()
    evidence = Any[]
    @testset "Newborn instruction executions preserve independent live scientific state" begin
        for count in (1, 3)
            reference = PSE.run!(_rng_fixture(count); steps=0, outputs)
            candidate = C._prepare(_rng_fixture(count); enable! = _enable!, outputs)
            previous = C._initial_pair(reference, candidate)
            cells = map(simulation -> PSE.refvalue(PSE.model_status(simulation.model, 1), :signal),
                (reference, candidate))
            PSE.step!(reference); PSE.step!(candidate)
            previous = _state(reference, candidate, previous)
            before = _report(candidate)
            cells[1][] = cells[2][] = 17.0f0
            for simulation in (reference, candidate)
                PSE.register_object!(simulation.model, C._unit(count+1))
                PSE.register_object!(simulation.model, PSE.Object(:new; kind=:growth_input_gatherer))
                PSE.register_object!(simulation.model, C._unit(count+2; parent=:new))
                PSE.step!(simulation)
                for id in 1:count+2
                    @test PSE.model_status(simulation.model, id).observed isa Float32
                end
                @test !isempty(simulation.compiled.input_bindings_by_target[(:inferred, PSE.ObjectId(count+1))])
            end
            previous = _state(reference, candidate, previous)
            push!(evidence, (; count, phase=:birth, _evidence(candidate; before, require_execution=true)...))
            retired = map(simulation -> PSE.refvalue(PSE.model_status(simulation.model, 2), :signal),
                (reference, candidate))
            retired_values = map(cell -> cell[], retired)
            for simulation in (reference, candidate)
                PSE.reparent_object!(simulation.model, count+1, :right)
                PSE.remove_object!(simulation.model, 2)
                PSE.step!(simulation)
            end
            previous = _state(reference, candidate, previous)
            for (index, simulation) in pairs((reference, candidate))
                PSE.register_object!(simulation.model, C._unit(2; value=30.0f0))
                PSE.step!(simulation)
                @test PSE.refvalue(PSE.model_status(simulation.model, 2), :signal) !== retired[index]
                @test retired[index][] === retired_values[index]
                @test PSE.refvalue(PSE.model_status(simulation.model, 1), :signal) === cells[index]
            end
            _state(reference, candidate, previous)
        end
    end
    return (; passed=true, outputs, evidence,
        oracle=:ordinary_exact_state_raw_history_rng_and_live_binding_references)
end

function _outcome_pair(reference, candidate, left, right; kwargs...)
    a = _C()._binding_outcome(reference, left; kwargs...)
    b = _C()._binding_outcome(candidate, right; kwargs...)
    @test isequal(a.error, b.error)
    @test _C()._binding_description.(a.bindings) == _C()._binding_description.(b.bindings)
    return b
end
function _updates_fixture()
    return PSE.CompositeModel(PSE.Object(1; kind=:updates_unit);
        applications=(
            PSE.ModelSpec(Writer(1.0f0); name=:source_a, on=PSE.Many(kind=:updates_unit), every=Hour(1)),
            PSE.ModelSpec(Writer(2.0f0); name=:source_b, on=PSE.Many(kind=:updates_unit), every=Hour(1),
                updates=PSE.Updates(:signal; after=:source_a)),
            PSE.ModelSpec(_C().Inferred(); name=:reader, on=PSE.Many(kind=:updates_unit), every=Hour(1),
                inputs=(signal=PSE.One(within=PSE.Self(), var=:signal),)),
        ), environment=(duration=Hour(1),))
end

"""Live membership, current plan fields, manual targets, ambiguity and partial errors."""
function newborn_binding_guard_checks()
    C = _C()
    reference = PSE.run!(C._generic_fixture(1); steps=0, outputs=:none)
    candidate = C._prepare(C._generic_fixture(1); enable! = _enable!, outputs=:none)
    a = only(plan for plan in reference.compiled.scenario_plan.input_plans if plan.application_id === :inferred)
    b = only(plan for plan in candidate.compiled.scenario_plan.input_plans if plan.application_id === :inferred)
    left, right = PSE.CompiledModelInputPlan[a], PSE.CompiledModelInputPlan[b]
    @testset "Newborn programs resolve current sources and preserve compiler errors" begin
        @test length(_outcome_pair(reference, candidate, left, right).bindings) == 1
        @test length(_outcome_pair(reference, candidate, left, right).bindings) == 1
        for simulation in (reference, candidate)
            empty!(simulation.compiled.applications_by_id[:source].target_ids)
        end
        @test isempty(_outcome_pair(reference, candidate, left, right).bindings)
        for simulation in (reference, candidate)
            push!(simulation.compiled.applications_by_id[:source].target_ids, PSE.ObjectId(1))
        end
        @test length(_outcome_pair(reference, candidate, left, right).bindings) == 1
        left[1], right[1] = C._plan_with(a; source_var=:not_written), C._plan_with(b; source_var=:not_written)
        @test isempty(_outcome_pair(reference, candidate, left, right).bindings)
        left[1], right[1] = a, b
        @test isempty(_outcome_pair(reference, candidate, left, right; manual_ids=Set([:inferred])).bindings)
        push!(left, a); push!(right, b)
        ambiguous = _outcome_pair(reference, candidate, left, right)
        @test ambiguous.error !== nothing
        @test ambiguous.error !== nothing && occursin("ambiguous same-object producers", ambiguous.error[2])
        # A late rejection may not replay the already appended explicit input.
        pushfirst!(left, C._plan_with(a; input=:untouched, origin=:model_spec))
        pushfirst!(right, C._plan_with(b; input=:untouched, origin=:model_spec))
        partial = _outcome_pair(reference, candidate, left, right)
        @test partial.error !== nothing
        @test length(partial.bindings) == 1
    end
    reference = PSE.run!(_updates_fixture(); steps=0, outputs=:all)
    candidate = C._prepare(_updates_fixture(); enable! = _enable!, outputs=:all)
    @testset "Newborn explicit binding retains Updates final writer" begin
        previous = C._initial_pair(reference, candidate)
        for simulation in (reference, candidate)
            PSE.step!(simulation)
            PSE.register_object!(simulation.model, PSE.Object(2; kind=:updates_unit))
            PSE.step!(simulation)
            @test PSE.model_status(simulation.model, 2).observed === 2.0f0
            binding = only(simulation.compiled.input_bindings_by_target[(:reader, PSE.ObjectId(2))])
            @test binding.source_application_ids == [:source_b]
        end
        _state(reference, candidate, previous)
    end
    return (; passed=true, evidence=_evidence(candidate),
        oracle=:ordinary_current_writer_final_ownership_and_partial_error_equivalence)
end

"""One trusted targeted initializer, multirate or distributed fallback case."""
function newborn_binding_feature_checks(case::Symbol=:initializer; outputs=:all,
    expected_fallback_reasons=())
    C, N = _C(), getfield(Main, :NewbornPreparationChecks)
    if case in (:initializer, :mixed_cadence, :later_addition)
        cadence = case === :mixed_cadence ? Hour(2) : Hour(1)
        mutation = case === :later_addition ? :later_addition : :none
        left = N.preparation_fixture(; source_every=cadence, mutation).model
        right = N.preparation_fixture(; source_every=cadence, mutation).model
        steps = case === :mixed_cadence ? 4 : 3
    elseif case === :distributed
        D = getfield(Main, :NewbornDistributedChecks)
        left, right = D.distributed_fixture(:from_status), D.distributed_fixture(:from_status)
        steps = 3
    else
        throw(ArgumentError("Choose :initializer, :mixed_cadence, :later_addition or :distributed"))
    end
    reference = PSE.run!(left; steps=0, outputs)
    candidate = C._prepare(right; enable! = _enable!, outputs)
    before = _report(candidate)
    @testset "Newborn instructions preserve existing $case feature" begin
        previous = C._initial_pair(reference, candidate)
        for _ in 1:steps
            PSE.step!(reference); PSE.step!(candidate)
            previous = _state(reference, candidate, previous)
            @test isequal(N._snapshot(candidate), N._snapshot(reference))
        end
        observed = _report(candidate)
        for reason in expected_fallback_reasons
            @test get(observed.misses, reason, 0) > get(before.misses, reason, 0)
        end
    end
    return (; passed=true, case, outputs, evidence=_evidence(candidate; before),
        expected_fallback_reasons,
        fallback_qualification=isempty(expected_fallback_reasons) ?
            :parity_and_actual_counters_no_specific_fallback_claim : :requested_fallback_reasons_observed,
        oracle=:ordinary_targeted_initializer_temporal_distributed_exact_history_and_refs)
end

"""Same model types change declaration fields; fresh logical compile/timeline."""
function newborn_binding_recompile_checks()
    C = _C()
    left, right = C._declaration_fixture(), C._declaration_fixture()
    reference = PSE.run!(left.model; steps=0, outputs=:all)
    candidate = C._prepare(right.model; enable! = _enable!, outputs=:all)
    @testset "Newborn instructions follow current same-type declarations" begin
        previous = C._initial_pair(reference, candidate)
        for simulation in (reference, candidate)
            PSE.register_object!(simulation.model, PSE.Object(2; kind=:declaration_unit))
            PSE.step!(simulation)
        end
        _state(reference, candidate, previous)
        for fixture in (left, right)
            fixture.source_port[] = fixture.reader_port[] = :beta
            PSE.Advanced.refresh_bindings!(fixture.model; force=true)
        end
        reference = PSE.run!(left.model; steps=0, outputs=:all)
        candidate = PSE.run!(right.model; steps=0, outputs=:all)
        previous = C._initial_pair(reference, candidate)
        before = _report(candidate)
        for simulation in (reference, candidate)
            PSE.register_object!(simulation.model, PSE.Object(3; kind=:declaration_unit))
            PSE.step!(simulation)
            @test all(plan -> plan.input === :beta, simulation.compiled.scenario_plan.input_plans)
            @test PSE.model_status(simulation.model, 3).seen === 2.0f0
            binding = only(simulation.compiled.input_bindings_by_target[(:reader, PSE.ObjectId(3))])
            @test binding.input === binding.source_var === :beta
        end
        _state(reference, candidate, previous)
        report = _report(candidate)
        # outputs_ reads a mutable port Ref in this fixture. Strict declaration
        # admission must reject it both before and after fresh compilation.
        rejected = get(report.compile_skips, :output_declaration_effects, 0) +
            get(report.compile_skips, :output_names_not_concrete, 0)
        @test rejected > 0
        return (; passed=true, evidence=_evidence(candidate; before, require_execution=false),
            qualification=:strict_dynamic_declaration_fallback)
    end
end

"""Original PB/XP two-step independent science; report actual birth work honestly."""
function newborn_binding_downstream_checks(kind::Symbol=:pb; outputs=:all)
    kind in (:pb, :xp) || throw(ArgumentError("Choose :pb or :xp"))
    C, F, H = _C(), _F(), getfield(Main, :DirectPlannerMeasurements)
    config = H.construct_config(kind; steps=2, nobjects=2, outputs)
    left, right = F.construct_fixture(kind, config), F.construct_fixture(kind, config)
    reference = PSE.run!(left.model; steps=0, outputs)
    candidate = C._prepare(right.model; enable! = _enable!, outputs)
    before = _report(candidate)
    @testset "Original downstream science under newborn binding instructions" begin
        previous = C._initial_pair(reference, candidate; kind)
        for _ in 1:2
            PSE.step!(reference); PSE.step!(candidate)
            previous = _state(reference, candidate, previous; kind)
        end
        CR = getfield(Main, :CompiledRegionsExperiment)
        @test CR.downstream_work_report(candidate, right.initial_ids) == CR.downstream_work_report(reference, left.initial_ids)
    end
    births = length(setdiff(collect(PSE.object_ids(candidate.model)), right.initial_ids))
    return (; passed=true, kind, steps=2, outputs, births,
        evidence=_evidence(candidate; before, require_execution=kind === :xp && births > 0),
        qualification=iszero(births) ? :static_scientific_regression_not_newborn_coverage : :observed_original_growth,
        oracle=:independent_original_exact_state_history_rng_and_live_bindings)
end

# Strict metadata proof must inspect effects/types without executing outputs_
# on these live scientific objects. These methods deliberately expose effects
# which ordinary compilation must retain in its original number and order.
struct DeclarationCounterSource <: AbstractNewborn_Instruction_WriterModel
    calls::Base.RefValue{Int}
end
struct DeclarationRandomSource{R} <: AbstractNewborn_Instruction_WriterModel
    rng::R
end
struct DeclarationMutableNameSource <: AbstractNewborn_Instruction_WriterModel
    port::Base.RefValue{Symbol}
end
struct DeclarationGlobalNameSource <: AbstractNewborn_Instruction_WriterModel end
const _GLOBAL_OUTPUT_NAME = Ref(:signal)
const _DeclarationSources = Union{DeclarationCounterSource,DeclarationRandomSource,
    DeclarationMutableNameSource,DeclarationGlobalNameSource}
PSE.inputs_(::_DeclarationSources) = NamedTuple()
function PSE.outputs_(model::DeclarationCounterSource)
    model.calls[] += 1
    return (signal=0.0f0,)
end
PSE.outputs_(model::DeclarationRandomSource) = (signal=rand(model.rng, Float32),)
PSE.outputs_(model::DeclarationMutableNameSource) = NamedTuple{(model.port[],)}((0.0f0,))
PSE.outputs_(::DeclarationGlobalNameSource) = NamedTuple{(_GLOBAL_OUTPUT_NAME[],)}((0.0f0,))
function PSE.run!(model::_DeclarationSources, status, environment, constants, context)
    name = model isa DeclarationMutableNameSource ? model.port[] :
        model isa DeclarationGlobalNameSource ? _GLOBAL_OUTPUT_NAME[] : :signal
    setproperty!(status, name, 2.0f0)
    return nothing
end
_declaration_work(model::DeclarationCounterSource) = model.calls[]
_declaration_work(model::DeclarationRandomSource) = rand(copy(model.rng), UInt64, 4)
_declaration_work(model::DeclarationMutableNameSource) = model.port[]
_declaration_work(::DeclarationGlobalNameSource) = _GLOBAL_OUTPUT_NAME[]
_declaration_unit(id) = PSE.Object(id; kind=:declaration_effect_unit,
    status=(signal=3.0f0, beta=4.0f0))
function _declaration_effect_fixture(source)
    model = PSE.CompositeModel(_declaration_unit(1);
        applications=(
            PSE.ModelSpec(source; name=:source, on=PSE.Many(kind=:declaration_effect_unit), every=Hour(1)),
            PSE.ModelSpec(_C().Inferred(); name=:inferred,
                on=PSE.Many(kind=:declaration_effect_unit), every=Hour(1),
                inputs=(signal=PSE.One(within=PSE.Self(), application=:source, var=:signal),)),
        ), environment=(duration=Hour(1),))
    return (; model, source)
end
function _step_error(simulation)
    try
        PSE.step!(simulation)
        return nothing
    catch error
        return (typeof(error), sprint(showerror, error))
    end
end

"""Strict declaration admission adds no live metadata evaluation or RNG draw."""
function newborn_binding_declaration_checks()
    C, N = _C(), _program()
    evidence = Any[]
    @testset "Declaration effects and dynamic output names retain ordinary work" begin
        factories = (
            :counter => (() -> DeclarationCounterSource(Ref(0))),
            :rng => (() -> DeclarationRandomSource(MersenneTwister(41))),
            :mutable_name => (() -> DeclarationMutableNameSource(Ref(:signal))),
            :global_name => (() -> DeclarationGlobalNameSource()),
        )
        saved_name = _GLOBAL_OUTPUT_NAME[]
        try
            for (case, factory) in factories
                _GLOBAL_OUTPUT_NAME[] = :signal
                left, right = _declaration_effect_fixture(factory()), _declaration_effect_fixture(factory())
                reference = PSE.run!(left.model; steps=0, outputs=:all)
                candidate = C._prepare(right.model; enable! = _enable!, outputs=:all)
                previous = C._initial_pair(reference, candidate)
                @test isequal(_declaration_work(right.source), _declaration_work(left.source))
                plan = only(candidate.compiled.input_bindings_by_target[(:inferred, PSE.ObjectId(1))]).plan
                before = _declaration_work(right.source)
                instruction, reason = N._instruction(N.ProgramState(), plan, candidate.compiled.applications_by_id)
                @test instruction === nothing
                @test reason in (:output_declaration_effects, :output_names_not_concrete)
                @test isequal(_declaration_work(right.source), before)
                if case in (:mutable_name, :global_name)
                    # The old signal Ref remains present, but current outputs_
                    # no longer declares it. A new consumer must take the same
                    # ordinary no-producer error rather than bind that old cell.
                    case === :mutable_name && (left.source.port[] = right.source.port[] = :beta)
                    case === :global_name && (_GLOBAL_OUTPUT_NAME[] = :beta)
                    for simulation in (reference, candidate)
                        @test PSE.refvalue(PSE.model_status(simulation.model, 1), :signal) isa Ref
                        PSE.register_object!(simulation.model, _declaration_unit(2))
                    end
                    left_error, right_error = _step_error(reference), _step_error(candidate)
                    @test left_error !== nothing
                    @test isequal(right_error, left_error)
                else
                    for simulation in (reference, candidate)
                        PSE.register_object!(simulation.model, _declaration_unit(2))
                        PSE.step!(simulation)
                    end
                    _state(reference, candidate, previous)
                end
                @test isequal(_declaration_work(right.source), _declaration_work(left.source))
                push!(evidence, (; case, reason, report=_report(candidate)))
            end
        finally
            _GLOBAL_OUTPUT_NAME[] = saved_name
        end
        # A mutable RNG field is harmless when outputs_ never reads it.
        reference = PSE.run!(_rng_fixture(1); steps=0, outputs=:all)
        candidate = C._prepare(_rng_fixture(1); enable! = _enable!, outputs=:all)
        previous = C._initial_pair(reference, candidate)
        before = _report(candidate)
        for simulation in (reference, candidate)
            PSE.register_object!(simulation.model, C._unit(2))
            PSE.step!(simulation)
        end
        _state(reference, candidate, previous)
        after = _report(candidate)
        @test after.counters.producer_instruction_executions > before.counters.producer_instruction_executions
        push!(evidence, (; case=:constant_outputs_with_rng,
            _evidence(candidate; before, require_execution=true)...))
    end
    return (; passed=true, evidence,
        oracle=:ordinary_declaration_call_count_rng_state_and_current_output_names)
end

"""Same slot is insufficient after selector, policy, status or producer changes."""
function newborn_binding_header_checks()
    C, N = _C(), _program()
    simulation = C._prepare(_rng_fixture(1); enable! = _enable!, outputs=:none)
    compiled = simulation.compiled
    application = compiled.applications_by_id[:inferred]
    plan = only(compiled.input_bindings_by_target[(:inferred, PSE.ObjectId(1))]).plan
    execute = candidate -> PSE._try_newborn_binding_instruction!(PSE.CompiledModelInputBinding[],
        simulation.model, application, PSE.ObjectId(1), candidate,
        compiled.applications_by_object, compiled.applications_by_id, nothing,
        compiled.distributed_outputs, nothing)
    @testset "Instruction headers reject same-slot semantic changes" begin
        @test execute(plan) === true
        selectors = (
            PSE.One(id=1, within=PSE.SceneScope(), application=:source, var=:signal),
            PSE.One(within=PSE.Self(), application=:source, var=:signal,
                policy=PSE.PreviousTimeStep(:signal)),
            PSE.One(within=PSE.Self(), var=:signal, from_status=true),
            PSE.One(within=PSE.Self(), application=:other, var=:signal),
        )
        for selector in selectors
            status_source = PSE._selector_from_status(selector)
            producer = PSE._selector_application(selector)
            changed = C._plan_with(plan; selector,
                matcher=PSE._compile_selector_matcher(simulation.model, selector),
                process=status_source ? nothing : plan.process,
                application=producer,
                potential_source_application_ids=status_source ? () : (producer,))
            @test changed.slot == plan.slot
            before = get(_report(simulation).misses, :plan_header_changed, 0)
            @test execute(changed) === false
            @test get(_report(simulation).misses, :plan_header_changed, 0) > before
        end
        @test execute(plan) === true
    end
    return (; passed=true, report=_report(simulation))
end

end # module
