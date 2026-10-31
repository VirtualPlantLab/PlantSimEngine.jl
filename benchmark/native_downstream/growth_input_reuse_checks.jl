module GrowthInputReuseChecks

using Dates, Test, PlantSimEngine
const PSE = PlantSimEngine

export growth_input_generic_checks, growth_input_partition_checks, growth_input_declaration_checks,
    growth_input_feature_checks, growth_input_downstream_checks

# These are cheap paired correctness checks, never benchmark setup. Load the
# existing direct-planner fixtures and the opt-in candidate before calling them.
_fixtures() = getfield(Main, :DirectPlannerFixtures)
_enable!(model) = Base.invokelatest(
    getfield(getfield(Main, :GrowthInputReuse), :enable_growth_input_reuse!), model)
_report(simulation) = Base.invokelatest(
    getfield(getfield(Main, :GrowthInputReuse), :growth_input_reuse_report), simulation)

function _checked_report(report, simulation; positive=false)
    observed = Base.invokelatest(report, simulation)
    @test observed.enabled
    @test observed.cached_bindings === false
    @test observed.cached_source_membership === false
    @test observed.cached_defaults === false
    if positive
        @test observed.handled_consumers > 0
        @test observed.partition_hits > 0
        @test observed.appended_bindings > 0
    end
    return observed
end

function _prepare(model; enable! = _enable!, kwargs...)
    Base.invokelatest(enable!, model)
    return Base.invokelatest(PSE.run!, model; steps=0, kwargs...)
end

function _pair_state(reference, candidate, previous; kind=:generic)
    F = _fixtures()
    @test isequal(F.snapshot(candidate, kind), F.snapshot(reference, kind))
    @test F.scientific_rngs(candidate.model) == F.scientific_rngs(reference.model)
    current = (F.identities(reference.model), F.identities(candidate.model))
    @test F.same_identity_transitions(previous[1], previous[2], current[1], current[2])
    return current
end

function _initial_pair(reference, candidate; kind=:generic)
    F = _fixtures()
    left, right = F.identities(reference.model), F.identities(candidate.model)
    @test keys(left.references) == keys(right.references)
    @test all(key -> left.references[key] !== right.references[key], keys(left.references))
    return _pair_state(reference, candidate, (left, right); kind)
end

function _live_bindings(simulation)
    for binding in simulation.compiled.input_bindings
        binding.carrier_hint === :temporal_stream && continue
        isnothing(binding.carrier) && continue
        if binding.multiplicity === :many
            refs = parent(binding.carrier)
            @test length(refs) == length(binding.source_ids)
            for (index, id) in pairs(binding.source_ids)
                @test refs[index] === PSE.refvalue(
                    PSE.model_status(simulation.model, id), binding.source_var)
            end
            view = simulation.compiled.status_views_by_target[
                (binding.application_id, binding.consumer_id)]
            bound = getproperty(view.bound_inputs, binding.input)
            @test collect(PSE.object_ids(bound)) == binding.source_ids
            @test bound.values === binding.carrier
        else
            @test length(binding.source_ids) == 1
            @test binding.carrier === PSE.refvalue(
                PSE.model_status(simulation.model, only(binding.source_ids)), binding.source_var)
        end
    end
    return nothing
end

PSE.@process "growth_input_check_source" verbose=false
PSE.@process "growth_input_check_inferred" verbose=false
PSE.@process "growth_input_check_gather" verbose=false
PSE.@process "growth_input_check_declaration" verbose=false

struct Source <: AbstractGrowth_Input_Check_SourceModel end
PSE.inputs_(::Source) = NamedTuple()
PSE.outputs_(::Source) = (signal=0.0f0, visits=0)
function PSE.run!(::Source, status, environment, constants, context)
    status.signal += 1.0f0
    status.visits += 1
    return nothing
end

struct Inferred <: AbstractGrowth_Input_Check_InferredModel end
PSE.inputs_(::Inferred) = (signal=PSE.Required(Float32), untouched=PSE.Default(3.0f0))
PSE.outputs_(::Inferred) = (observed=0.0f0, observed_default=0.0f0)
function PSE.run!(::Inferred, status, environment, constants, context)
    status.observed = status.signal
    status.observed_default = status.untouched
    return nothing
end

struct Gather <: AbstractGrowth_Input_Check_GatherModel end
PSE.inputs_(::Gather) = (single=PSE.Required(Float32),
    optional=PSE.Default(-1.0f0), signals=PSE.Required(Vector{Float32}),
    all_signals=PSE.Required(Vector{Float32}))
PSE.outputs_(::Gather) = (total=0.0f0, seen_single=0.0f0, seen_optional=0.0f0,
    seen_ids=PSE.ObjectId[], seen_values=Float32[],
    all_ids=PSE.ObjectId[], all_values=Float32[])
function PSE.run!(::Gather, status, environment, constants, context)
    values = PSE.bound_input(context, :signals)
    status.total = sum(values; init=0.0f0)
    status.seen_single = status.single
    status.seen_optional = status.optional
    status.seen_ids = collect(PSE.object_ids(values))
    status.seen_values = collect(values)
    all_values = PSE.bound_input(context, :all_signals)
    status.all_ids = collect(PSE.object_ids(all_values))
    status.all_values = collect(all_values)
    return nothing
end

_unit(id; parent=:left, value=0.0f0) = PSE.Object(id;
    kind=:growth_input_unit, parent, status=(signal=value, visits=0))
function _generic_fixture(nobjects)
    nobjects in (1, 3) || throw(ArgumentError("Use one or three initial Float32 sources"))
    return PSE.CompositeModel(PSE.Object(:left; kind=:growth_input_gatherer),
        PSE.Object(:right; kind=:growth_input_gatherer),
        (_unit(id) for id in 1:nobjects)...;
        applications=(
            PSE.ModelSpec(Source(); name=:source, on=PSE.Many(kind=:growth_input_unit), every=Hour(1)),
            PSE.ModelSpec(Inferred(); name=:inferred, on=PSE.Many(kind=:growth_input_unit), every=Hour(1)),
            PSE.ModelSpec(Gather(); name=:gather, on=PSE.Many(kind=:growth_input_gatherer), every=Hour(1),
                inputs=(single=PSE.One(id=1, within=PSE.SceneScope(), application=:source, var=:signal),
                    optional=PSE.OptionalOne(id=2, within=PSE.SceneScope(), application=:source, var=:signal),
                    signals=PSE.Many(kind=:growth_input_unit, within=PSE.Subtree(),
                        application=:source, var=:signal),
                    all_signals=PSE.Many(kind=:growth_input_unit, within=PSE.SceneScope(),
                        application=:source, var=:signal))),
        ), environment=(duration=Hour(1),))
end

"""Float32 scalar inference and One/OptionalOne/Many over live canonical cells.

The one-source arm includes an initially absent OptionalOne and singleton Many;
the three-source arm includes shared Many carriers. Growth adds both sources
and consumers. Removal/reparenting/re-registration exercise ordinary fallbacks.
"""
function growth_input_generic_checks(; enable! = _enable!, report = _report, outputs=:all)
    reports = Any[]
    @testset "Growth input partition preserves Float32 live carriers" begin
        for nobjects in (1, 3)
            reference = PSE.run!(_generic_fixture(nobjects); steps=0, outputs)
            candidate = _prepare(_generic_fixture(nobjects); enable!, outputs)
            previous = _initial_pair(reference, candidate)
            left_cell = PSE.refvalue(PSE.model_status(reference.model, 1), :signal)
            right_cell = PSE.refvalue(PSE.model_status(candidate.model, 1), :signal)
            for simulation in (reference, candidate)
                PSE.step!(simulation)
                _live_bindings(simulation)
                shared = [binding for binding in simulation.compiled.input_bindings
                    if binding.application_id === :gather && binding.input === :all_signals]
                @test length(shared) == 2
                @test all(binding -> binding.source_ids === first(shared).source_ids, shared)
                @test all(binding -> binding.carrier === first(shared).carrier, shared)
            end
            previous = _pair_state(reference, candidate, previous)
            left_cell[] = right_cell[] = 10.25f0
            for simulation in (reference, candidate)
                PSE.register_object!(simulation.model, _unit(nobjects+1))
                PSE.register_object!(simulation.model, PSE.Object(:new; kind=:growth_input_gatherer))
                PSE.register_object!(simulation.model, _unit(nobjects+2; parent=:new))
                PSE.step!(simulation)
                _live_bindings(simulation)
                @test PSE.model_status(simulation.model, 1).signal === 11.25f0
                shared = [binding for binding in simulation.compiled.input_bindings
                    if binding.application_id === :gather && binding.input === :all_signals]
                @test length(shared) == 3
                @test all(binding -> binding.source_ids === first(shared).source_ids, shared)
                @test all(binding -> binding.carrier === first(shared).carrier, shared)
                @test PSE.model_status(simulation.model, :new).seen_ids == [PSE.ObjectId(nobjects+2)]
                @test isempty(PSE.model_status(simulation.model, :right).seen_ids)
                for id in (1:nobjects+2)
                    state = PSE.model_status(simulation.model, id)
                    @test state.observed === state.signal
                    @test state.observed_default === 3.0f0
                    @test :untouched in simulation.model.input_default_status_variables[PSE.ObjectId(id)]
                    @test !(:signal in simulation.model.input_default_status_variables[PSE.ObjectId(id)])
                end
            end
            previous = _pair_state(reference, candidate, previous)
            optional_cells = map(simulation -> PSE.refvalue(
                PSE.model_status(simulation.model, :left), :optional), (reference, candidate))
            retired_cells = map(simulation -> PSE.refvalue(
                PSE.model_status(simulation.model, 2), :signal), (reference, candidate))
            retired_values = map(cell -> cell[], retired_cells)
            for (index, simulation) in pairs((reference, candidate))
                PSE.reparent_object!(simulation.model, nobjects+1, :right)
                PSE.remove_object!(simulation.model, 2)
                PSE.step!(simulation)
                _live_bindings(simulation)
                @test PSE.refvalue(PSE.model_status(simulation.model, :left), :optional) === optional_cells[index]
                @test optional_cells[index][] === retired_values[index]
            end
            previous = _pair_state(reference, candidate, previous)
            for (index, simulation) in pairs((reference, candidate))
                PSE.register_object!(simulation.model, _unit(2; value=30.0f0))
                PSE.step!(simulation)
                _live_bindings(simulation)
                @test PSE.model_status(simulation.model, :left).seen_optional === 31.0f0
                @test PSE.refvalue(PSE.model_status(simulation.model, 2), :signal) !== retired_cells[index]
                @test retired_cells[index][] === retired_values[index]
            end
            previous = _pair_state(reference, candidate, previous)
            @test PSE.refvalue(PSE.model_status(reference.model, 1), :signal) === left_cell
            @test PSE.refvalue(PSE.model_status(candidate.model, 1), :signal) === right_cell
            observed = _checked_report(report, candidate; positive=true)
            @test observed.singleton_writer_checks > 0
            @test observed.singleton_binding_dispatches > 0
            push!(reports, (; nobjects, report=observed))
        end
    end
    return (; passed=true, outputs, reports,
        oracle=:ordinary_per_step_exact_state_history_and_canonical_reference_identity)
end

function _plan_with(plan; kwargs...)
    changes = (; kwargs...)
    values = map(fieldnames(typeof(plan))) do name
        haskey(changes, name) ? getproperty(changes, name) : getfield(plan, name)
    end
    return PSE.CompiledModelInputPlan(values...)
end

function _compile_inputs!(destination, simulation, plans;
    manual_ids=Set{Symbol}(), applications_by_id=simulation.compiled.applications_by_id)
    compiled = simulation.compiled
    application = compiled.applications_by_id[:inferred]
    return PSE._compile_added_consumer_bindings!(destination, simulation.model,
        application, PSE.ObjectId(1), plans, manual_ids,
        compiled.applications_by_object, applications_by_id,
        compiled.distributed_outputs, nothing, nothing)
end

_binding_description(binding) = (binding.application_id, binding.consumer_id,
    binding.input, binding.source_ids, binding.source_application_ids,
    binding.source_var, binding.origin, binding.carrier_hint)
function _binding_outcome(simulation, plans; kwargs...)
    bindings = PSE.CompiledModelInputBinding[]
    try
        _compile_inputs!(bindings, simulation, plans; kwargs...)
        return (; error=nothing, bindings)
    catch exception
        return (; error=(typeof(exception), sprint(showerror, exception)), bindings)
    end
end

"""Mutate the plan vector in place and compare original binding semantics.

These inputs are valid compiled-plan objects. Only the private helper is called:
no malformed logical graph is installed into a live Simulation. The checks
exercise same-shape changed source fields, tag/length invalidation, a live
negative-to-positive writer transition, manual-target suppression, and the
existing multiproducer ambiguity error without relying on scheduler order.
"""
function growth_input_partition_checks(; enable! = _enable!, report = _report)
    reference = PSE.run!(_generic_fixture(1); steps=0, outputs=:none)
    candidate = _prepare(_generic_fixture(1); enable!, outputs=:none)
    left_plan = only(plan for plan in reference.compiled.scenario_plan.input_plans
        if plan.application_id === :inferred)
    right_plan = only(plan for plan in candidate.compiled.scenario_plan.input_plans
        if plan.application_id === :inferred)
    left_plans = PSE.CompiledModelInputPlan[left_plan]
    right_plans = PSE.CompiledModelInputPlan[right_plan]
    reports = Any[]
    @testset "Cached partitions validate current tags and resolve current plans" begin
        function compare!(; kwargs...)
            left = _binding_outcome(reference, left_plans; kwargs...)
            right = _binding_outcome(candidate, right_plans; kwargs...)
            @test isequal(left.error, right.error)
            @test _binding_description.(left.bindings) == _binding_description.(right.bindings)
            return right
        end
        @test length(compare!().bindings) == 1
        @test length(compare!().bindings) == 1
        # Shape matches, but actual source_var must be read from today's plan.
        left_plans[1] = _plan_with(left_plan; source_var=:not_written)
        right_plans[1] = _plan_with(right_plan; source_var=:not_written)
        @test isempty(compare!().bindings)
        left_plans[1], right_plans[1] = left_plan, right_plan
        @test length(compare!().bindings) == 1

        # Same vector, different origin/input/selector cardinality and length.
        left_plans[1] = _plan_with(left_plan; input=:renamed)
        right_plans[1] = _plan_with(right_plan; input=:renamed)
        @test only(compare!().bindings).input === :renamed
        left_plans[1] = _plan_with(left_plan; origin=:model_spec)
        right_plans[1] = _plan_with(right_plan; origin=:model_spec)
        @test length(compare!().bindings) == 1
        left_plans[1] = _plan_with(left_plan; selector=PSE.Many(within=PSE.Self(),
            application=:source, var=:signal), multiplicity=:many, origin=:model_spec)
        right_plans[1] = _plan_with(right_plan; selector=PSE.Many(within=PSE.Self(),
            application=:source, var=:signal), multiplicity=:many, origin=:model_spec)
        @test length(compare!().bindings) == 1
        empty!(left_plans); empty!(right_plans)
        @test isempty(compare!().bindings)
        push!(left_plans, left_plan); push!(right_plans, right_plan)
        @test isempty(compare!(manual_ids=Set([:inferred])).bindings)
        @test length(compare!().bindings) == 1

        # An absent current writer cannot become a permanent negative cache hit.
        for simulation in (reference, candidate)
            source = simulation.compiled.applications_by_id[:source]
            empty!(source.target_ids)
        end
        @test isempty(compare!().bindings)
        for simulation in (reference, candidate)
            push!(simulation.compiled.applications_by_id[:source].target_ids, PSE.ObjectId(1))
        end
        @test length(compare!().bindings) == 1
        push!(left_plans, left_plan); push!(right_plans, right_plan)
        ambiguous = compare!()
        @test ambiguous.error !== nothing
        @test occursin("ambiguous same-object producers", ambiguous.error[2])
        @test isempty(ambiguous.bindings)
        observed = _checked_report(report, candidate; positive=true)
        @test observed.partition_rebuilds > 0
        @test observed.general_match_vectors > 0
        push!(reports, observed)
    end
    return (; passed=true, reports,
        oracle=:ordinary_helper_current_plan_binding_and_error_equivalence)
end

# Same concrete model types can expose distinct authored schemas. Mutable
# declarations force fresh logical compilation; cached partitions must follow
# the newly compiled plans rather than the model type or earlier port name.
struct DeclarationSource <: AbstractGrowth_Input_Check_DeclarationModel
    port::Base.RefValue{Symbol}
end
struct DeclarationReader <: AbstractGrowth_Input_Check_InferredModel
    port::Base.RefValue{Symbol}
end
PSE.inputs_(::DeclarationSource) = NamedTuple()
PSE.outputs_(model::DeclarationSource) = NamedTuple{(model.port[],)}((0.0f0,))
PSE.inputs_(model::DeclarationReader) = NamedTuple{(model.port[],)}((PSE.Required(Float32),))
PSE.outputs_(::DeclarationReader) = (seen=0.0f0,)
function PSE.run!(model::DeclarationSource, status, environment, constants, context)
    setproperty!(status, model.port[], getproperty(status, model.port[]) + 2.0f0)
    return nothing
end
function PSE.run!(model::DeclarationReader, status, environment, constants, context)
    status.seen = getproperty(status, model.port[])
    return nothing
end
function _declaration_fixture(port=:alpha)
    source_port, reader_port = Ref(port), Ref(port)
    model = PSE.CompositeModel(PSE.Object(1; kind=:declaration_unit);
        applications=(
            PSE.ModelSpec(DeclarationSource(source_port); name=:source,
                on=PSE.Many(kind=:declaration_unit), every=Hour(1)),
            PSE.ModelSpec(DeclarationReader(reader_port); name=:reader,
                on=PSE.Many(kind=:declaration_unit), every=Hour(1)),
        ), environment=(duration=Hour(1),))
    return (; model, source_port, reader_port)
end
function growth_input_declaration_checks(; enable! = _enable!, report = _report)
    @testset "Growth input cache follows fresh parameter-dependent declarations" begin
        left, right = _declaration_fixture(), _declaration_fixture()
        reference = PSE.run!(left.model; steps=0, outputs=:all)
        candidate = _prepare(right.model; enable!, outputs=:all)
        previous = _initial_pair(reference, candidate)
        for simulation in (reference, candidate)
            PSE.register_object!(simulation.model, PSE.Object(2; kind=:declaration_unit))
            PSE.step!(simulation)
        end
        previous = _pair_state(reference, candidate, previous)
        for fixture in (left, right)
            fixture.source_port[] = fixture.reader_port[] = :beta
            PSE.Advanced.refresh_bindings!(fixture.model; force=true)
        end
        # Directly changing a scientific declaration does not revise an
        # existing Simulation's compiled views. Start a fresh timeline from
        # the newly prepared logical model in both arms; do not imply that
        # force-refreshing the model replaces an active Simulation's views.
        reference = PSE.run!(left.model; steps=0, outputs=:all)
        candidate = PSE.run!(right.model; steps=0, outputs=:all)
        previous = _initial_pair(reference, candidate)
        for simulation in (reference, candidate)
            PSE.register_object!(simulation.model, PSE.Object(3; kind=:declaration_unit))
            PSE.step!(simulation)
            _live_bindings(simulation)
            @test all(plan -> plan.input === :beta, simulation.compiled.scenario_plan.input_plans)
            @test PSE.model_status(simulation.model, 3).seen === 2.0f0
        end
        _pair_state(reference, candidate, previous)
        return (; passed=true, report=_checked_report(report, candidate; positive=true),
            oracle=:fresh_compiled_declarations_with_same_concrete_model_types)
    end
end

"""One selected existing fixture: targeted initializer, multirate, or distributed.

The old newborn binding-promotion policy is enabled in neither arm. All actual
binding construction and scientific execution remain ordinary PSE operations.
"""
function growth_input_feature_checks(case::Symbol=:initializer;
    enable! = _enable!, report = _report, outputs=:all)
    Checks = getfield(Main, :NewbornPreparationChecks)
    if case in (:initializer, :mixed_cadence, :later_addition, :movement)
        source_every = case === :mixed_cadence ? Hour(2) : Hour(1)
        mutation = case in (:later_addition, :movement) ? case : :none
        left = Checks.preparation_fixture(; source_every, mutation)
        right = Checks.preparation_fixture(; source_every, mutation)
        steps = case === :mixed_cadence ? 4 : 3
        reference = PSE.run!(left.model; steps=0, outputs)
        candidate = _prepare(right.model; enable!, outputs)
        previous = _initial_pair(reference, candidate)
        cells = map(simulation -> PSE.refvalue(PSE.model_status(simulation.model, 1), :supply),
            (reference, candidate))
        @testset "Growth input reuse preserves targeted initialization and temporal sampling" begin
            for step in 1:steps
                PSE.step!(reference); PSE.step!(candidate)
                previous = _pair_state(reference, candidate, previous)
                @test isequal(Checks._snapshot(candidate), Checks._snapshot(reference))
                @test PSE.model_status(candidate.model, 0).second_sample ===
                    PSE.model_status(candidate.model, 0).first_sample + 1.0f0
                for (index, simulation) in pairs((reference, candidate))
                    @test PSE.refvalue(PSE.model_status(simulation.model, 1), :supply) === cells[index]
                    _live_bindings(simulation)
                end
                if case === :mixed_cadence && step == 2
                    cells[1][] = cells[2][] = 41.0f0
                end
            end
        end
    elseif case in (:distributed, :distributed_from_status)
        D = getfield(Main, :NewbornDistributedChecks)
        mode = case === :distributed ? :direct : :from_status
        reference = PSE.run!(D.distributed_fixture(mode); steps=0, outputs)
        candidate = _prepare(D.distributed_fixture(mode); enable!, outputs)
        previous = _initial_pair(reference, candidate)
        cells = map(simulation -> PSE.refvalue(PSE.model_status(simulation.model, 1), :distributed_signal),
            (reference, candidate))
        @testset "Growth input reuse preserves distributed binding ownership" begin
            for step in 1:3
                PSE.step!(reference); PSE.step!(candidate)
                previous = _pair_state(reference, candidate, previous)
                @test isequal(Checks._snapshot(candidate), Checks._snapshot(reference))
                for (index, simulation) in pairs((reference, candidate))
                    @test PSE.refvalue(PSE.model_status(simulation.model, 1), :distributed_signal) === cells[index]
                    @test cells[index][] === Float32(5 + step)
                    _live_bindings(simulation)
                end
            end
        end
    else
        throw(ArgumentError("Choose :initializer, :mixed_cadence, :later_addition, :movement, :distributed or :distributed_from_status"))
    end
    return (; passed=true, case, outputs, report=_checked_report(report, candidate; positive=true),
        oracle=:ordinary_per_step_exact_history_topology_temporal_and_live_refs)
end

"""Independent original PB/XP fixtures; no model methods are wrapped or changed."""
function growth_input_downstream_checks(kind::Symbol=:pb;
    enable! = _enable!, report = _report, steps=2, nobjects=2, outputs=:all)
    kind in (:pb, :xp) || throw(ArgumentError("Choose :pb or :xp"))
    F = _fixtures()
    H = getfield(Main, :DirectPlannerMeasurements)
    config = H.construct_config(kind; steps, nobjects, outputs)
    left, right = F.construct_fixture(kind, config), F.construct_fixture(kind, config)
    reference = PSE.run!(left.model; steps=0, outputs)
    candidate = _prepare(right.model; enable!, outputs)
    @testset "Original downstream science under growth input reuse" begin
        previous = _initial_pair(reference, candidate; kind)
        for _ in 1:steps
            PSE.step!(reference); PSE.step!(candidate)
            previous = _pair_state(reference, candidate, previous; kind)
            _live_bindings(candidate)
        end
        CR = getfield(Main, :CompiledRegionsExperiment)
        @test CR.downstream_work_report(candidate, right.initial_ids) ==
            CR.downstream_work_report(reference, left.initial_ids)
    end
    return (; passed=true, kind, steps, outputs,
        report=_checked_report(report, candidate),
        oracle=:independent_original_full_state_raw_history_rng_and_identity_transitions)
end

end # module
