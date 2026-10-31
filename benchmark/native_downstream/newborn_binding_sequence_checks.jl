module NewbornBindingSequenceChecks

using Dates, Random, Test, PlantSimEngine
const PSE = PlantSimEngine
export sequence_generic_checks, sequence_order_membership_checks,
    sequence_declaration_checks, sequence_header_world_checks,
    sequence_feature_checks, sequence_recompile_checks
_C() = getfield(Main, :GrowthInputReuseChecks)
_B() = getfield(Main, :NewbornBindingProgramChecks)
_Q() = getfield(Main, :NewbornBindingSequence)
_enable!(model) = Base.invokelatest(_Q().enable_newborn_binding_sequence!, model; details=true)
_report(value) = Base.invokelatest(_Q().newborn_binding_sequence_report, value)

function _evidence(simulation; before=nothing, positive=false)
    report = _report(simulation)
    @test report.enabled && report.details_enabled
    @test sum(row.executions for row in report.per_input; init=0) == report.counters.instruction_executions
    fields = (:consumer_program_executions, :instruction_executions,
        :synthesized_bindings, :newborn_positive_executions, :newborn_producer_executions)
    delta = before === nothing ? nothing : NamedTuple{fields}(Tuple(
        getproperty(report.counters, field)-getproperty(before.counters, field) for field in fields))
    if positive
        @test delta !== nothing
        @test all(field -> getproperty(delta, field)>0, fields)
    end
    return (; report, delta, interpretation=:actual_nonempty_sequence_binding_work)
end
function _pair(factory; steps=2, mutate! = (model, step)->nothing)
    C, B = _C(), _B()
    reference = PSE.run!(factory(); steps=0, outputs=:all)
    candidate = C._prepare(factory(); enable! = _enable!, outputs=:all)
    previous = C._initial_pair(reference, candidate)
    before = _report(candidate)
    for step in 1:steps
        mutate!(reference.model, step); mutate!(candidate.model, step)
        PSE.step!(reference); PSE.step!(candidate)
        previous = B._state(reference, candidate, previous)
    end
    return (; reference, candidate, before)
end

"""Independent Float32/RNG, One/OptionalOne/Many, births and escaped references."""
function sequence_generic_checks()
    C = _C()
    @testset "Sequence executes real newborn producer bindings" begin
        result = _pair(() -> _B()._rng_fixture(1); mutate! = (model, step)->begin
            step==2 || return nothing
            PSE.register_object!(model, C._unit(2))
            PSE.register_object!(model, PSE.Object(:new; kind=:growth_input_gatherer))
            PSE.register_object!(model, C._unit(3; parent=:new))
        end)
        cells = map(simulation -> PSE.refvalue(PSE.model_status(simulation.model, 1), :signal),
            (result.reference, result.candidate))
        cells[1][] = cells[2][] = 17.0f0
        previous = C._initial_pair(result.reference, result.candidate)
        for simulation in (result.reference, result.candidate)
            PSE.remove_object!(simulation.model, 2)
            PSE.reparent_object!(simulation.model, 3, :right)
            PSE.step!(simulation)
        end
        previous = _B()._state(result.reference, result.candidate, previous)
        for (index, simulation) in pairs((result.reference, result.candidate))
            PSE.register_object!(simulation.model, C._unit(2; value=30.0f0))
            PSE.step!(simulation)
            @test PSE.refvalue(PSE.model_status(simulation.model, 1), :signal) === cells[index]
        end
        _B()._state(result.reference, result.candidate, previous)
        return (; passed=true, evidence=_evidence(result.candidate; before=result.before, positive=true))
    end
end

PSE.@process "sequence_mixed_reader" verbose=false
PSE.@process "sequence_distributed_writer" verbose=false
struct MixedReader <: AbstractSequence_Mixed_ReaderModel end
PSE.inputs_(::MixedReader) = (signal=PSE.Required(Float32), mirrored=PSE.Required(Float32), spare=PSE.Default(3.0f0))
PSE.outputs_(::MixedReader) = (seen_inferred=0.0f0, seen_explicit=0.0f0)
function PSE.run!(::MixedReader, status, environment, constants, context)
    status.seen_inferred=status.signal
    status.seen_explicit=status.mirrored
    return nothing
end
function _mixed_fixture()
    return PSE.CompositeModel(PSE.Object(1; kind=:sequence_unit, status=(signal=0.0f0,));
        applications=(
            PSE.ModelSpec(_B().RNGSource(MersenneTwister(11)); name=:source,
                on=PSE.Many(kind=:sequence_unit), every=Hour(1)),
            PSE.ModelSpec(MixedReader(); name=:inferred, on=PSE.Many(kind=:sequence_unit), every=Hour(1),
                inputs=(mirrored=PSE.One(within=PSE.Self(), application=:source, var=:signal),)),
        ), environment=(duration=Hour(1),))
end
function _outcome(simulation, plans; manual_ids=Set{Symbol}(), overlay=false)
    compiled=simulation.compiled
    by_object=compiled.applications_by_object
    if overlay
        source=compiled.applications_by_id[:source]
        partial=PSE.CompiledModelApplication(source.plan, PSE.ObjectId[PSE.ObjectId(1)])
        members=PSE.CompiledModelApplication[candidate for candidate in get(by_object,PSE.ObjectId(1),())
            if candidate.id!==:source]
        push!(members,partial)
        by_object=PSE._ApplicationsByObjectOverlay(by_object,Dict(PSE.ObjectId(1)=>members))
    end
    bindings=PSE.CompiledModelInputBinding[]
    try
        PSE._compile_added_consumer_bindings!(bindings, simulation.model,
            compiled.applications_by_id[:inferred], PSE.ObjectId(1), plans, manual_ids,
            by_object, compiled.applications_by_id, compiled.distributed_outputs, nothing, nothing)
        return (;error=nothing,bindings)
    catch exception
        return (;error=(typeof(exception),sprint(showerror,exception)),bindings)
    end
end
function _compare(reference,candidate,left,right;kwargs...)
    a,b=_outcome(reference,left;kwargs...),_outcome(candidate,right;kwargs...)
    @test isequal(a.error,b.error)
    @test _C()._binding_description.(a.bindings)==_C()._binding_description.(b.bindings)
    @test typeof.(getproperty.(a.bindings,:policy))==typeof.(getproperty.(b.bindings,:policy))
    return b
end
function _install_layout!(simulation,plans)
    Q=_Q();state=Q._enabled[simulation.model]
    logical=simulation.compiled.applications_by_id[:inferred]
    sequence=state.sequences[logical]
    state.sequences[logical]=Q._build_sequence(sequence.program,plans)
    return nothing
end

"""Explicit-first order, manual suppression, overlay-only nonmatches, late errors."""
function sequence_order_membership_checks()
    C=_C()
    reference=PSE.run!(_mixed_fixture();steps=0,outputs=:none)
    candidate=C._prepare(_mixed_fixture();enable! = _enable!,outputs=:none)
    plans(sim)=PSE.CompiledModelInputPlan[plan for plan in sim.compiled.scenario_plan.input_plans
        if plan.application_id===:inferred]
    left,right=reverse(plans(reference)),reverse(plans(candidate))
    _install_layout!(candidate,right)
    @testset "Sequence preserves ordinary order and inferred global membership" begin
        ordered=_compare(reference,candidate,left,right)
        @test getproperty.(ordered.bindings,:input)==[:mirrored,:signal]
        manual=_compare(reference,candidate,left,right;manual_ids=Set([:inferred]))
        @test getproperty.(manual.bindings,:input)==[:mirrored]
        # Keep only the inferred plan. A genuine targeted overlay may match a
        # scalar op, but ordinary inferred grouping requires GLOBAL membership.
        left=filter(plan->plan.origin===:inferred_same_object,left)
        right=filter(plan->plan.origin===:inferred_same_object,right)
        _install_layout!(candidate,right)
        for simulation in (reference,candidate)
            empty!(simulation.compiled.applications_by_id[:source].target_ids)
        end
        before=_report(candidate)
        @test isempty(_compare(reference,candidate,left,right;overlay=true).bindings)
        after=_report(candidate)
        @test after.counters.singleton_group_shortcuts==before.counters.singleton_group_shortcuts
        @test after.counters.instruction_executions==before.counters.instruction_executions
        for simulation in (reference,candidate)
            push!(simulation.compiled.applications_by_id[:source].target_ids,PSE.ObjectId(1))
        end
        @test length(_compare(reference,candidate,left,right;overlay=true).bindings)==1
        @test _report(candidate).counters.singleton_group_shortcuts>after.counters.singleton_group_shortcuts
        # A multi-match inferred group still throws after the explicit port;
        # ordinary partial destination contents may not be replayed or erased.
        a,b=only(left),only(right)
        explicit_a=only(filter(plan->plan.origin!==:inferred_same_object,plans(reference)))
        explicit_b=only(filter(plan->plan.origin!==:inferred_same_object,plans(candidate)))
        left=PSE.CompiledModelInputPlan[a,explicit_a,a]
        right=PSE.CompiledModelInputPlan[b,explicit_b,b]
        _install_layout!(candidate,right)
        failed=_compare(reference,candidate,left,right)
        @test failed.error!==nothing && occursin("ambiguous same-object producers",failed.error[2])
        @test getproperty.(failed.bindings,:input)==[:mirrored]
        @test _report(candidate).counters.general_inferred_groups>0
        return (;passed=true,evidence=_evidence(candidate))
    end
end

"""Same-slot semantic edits and a new method world take safe ordinary paths."""
function sequence_header_world_checks()
    C=_C()
    reference=PSE.run!(_B()._rng_fixture(1);steps=0,outputs=:none)
    candidate=C._prepare(_B()._rng_fixture(1);enable! = _enable!,outputs=:none)
    a=only(reference.compiled.input_bindings_by_target[(:inferred,PSE.ObjectId(1))]).plan
    b=only(candidate.compiled.input_bindings_by_target[(:inferred,PSE.ObjectId(1))]).plan
    @testset "Sequence rejects stale headers and method world" begin
        selectors=(PSE.One(id=1,within=PSE.SceneScope(),application=:source,var=:signal),
            PSE.One(within=PSE.Self(),application=:source,var=:signal,policy=PSE.PreviousTimeStep(:signal)),
            PSE.One(within=PSE.Self(),var=:signal,from_status=true),
            PSE.One(within=PSE.Self(),application=:missing,var=:signal))
        for selector in selectors
            make(plan,model)=C._plan_with(plan;selector,matcher=PSE._compile_selector_matcher(model,selector),
                origin=:model_spec,process=nothing,application=PSE._selector_application(selector),
                potential_source_application_ids=PSE._selector_from_status(selector) ? () : (PSE._selector_application(selector),))
            left=PSE.CompiledModelInputPlan[make(a,reference.model)]
            right=PSE.CompiledModelInputPlan[make(b,candidate.model)]
            _install_layout!(candidate,right)
            before=_report(candidate)
            _compare(reference,candidate,left,right)
            @test _report(candidate).counters.instruction_executions==before.counters.instruction_executions
        end
        left,right=PSE.CompiledModelInputPlan[a],PSE.CompiledModelInputPlan[b]
        _install_layout!(candidate,right)
        before=_report(candidate)
        marker=QuoteNode(gensym(:sequence_world_marker))
        Core.eval(@__MODULE__, :(_sequence_world_marker(::Val{$marker})=nothing))
        @test length(_compare(reference,candidate,left,right).bindings)==1
        after=_report(candidate)
        @test after.counters.consumer_program_executions==before.counters.consumer_program_executions
        @test get(after.misses,:method_world_changed,0)>get(before.misses,:method_world_changed,0)
        return (;passed=true,evidence=_evidence(candidate))
    end
end

"""Effectful/dynamic declarations preserve ordinary calls, RNG and rejection."""
function sequence_declaration_checks()
    C,B=_C(),_B();evidence=Any[]
    saved=B._GLOBAL_OUTPUT_NAME[]
    @testset "Sequence keeps conservative declaration proof" begin
        try
            for (case,factory) in (
                :counter=>(() -> B.DeclarationCounterSource(Ref(0))),
                :rng=>(() -> B.DeclarationRandomSource(MersenneTwister(41))),
                :mutable=>(() -> B.DeclarationMutableNameSource(Ref(:signal))),
                :global=>(() -> B.DeclarationGlobalNameSource()))
                B._GLOBAL_OUTPUT_NAME[]=:signal
                left,right=B._declaration_effect_fixture(factory()),B._declaration_effect_fixture(factory())
                reference=PSE.run!(left.model;steps=0,outputs=:all)
                candidate=C._prepare(right.model;enable! = _enable!,outputs=:all)
                previous=C._initial_pair(reference,candidate)
                @test isequal(B._declaration_work(left.source),B._declaration_work(right.source))
                if case in (:mutable,:global)
                    case===:mutable && (left.source.port[]=right.source.port[]=:beta)
                    case===:global && (B._GLOBAL_OUTPUT_NAME[]=:beta)
                    for simulation in (reference,candidate)
                        PSE.register_object!(simulation.model,B._declaration_unit(2))
                    end
                    left_error,right_error=B._step_error(reference),B._step_error(candidate)
                    @test left_error!==nothing
                    @test isequal(left_error,right_error)
                else
                    for simulation in (reference,candidate)
                        PSE.register_object!(simulation.model,B._declaration_unit(2));PSE.step!(simulation)
                    end
                    B._state(reference,candidate,previous)
                end
                @test isequal(B._declaration_work(left.source),B._declaration_work(right.source))
                report=_report(candidate)
                skips=report.base_program.compile_skips
                @test get(skips,:output_declaration_effects,0)+get(skips,:output_names_not_concrete,0)>0
                @test report.counters.instruction_executions==0
                @test report.counters.ordinary_binding_dispatches>0
                push!(evidence,(;case,report))
            end
        finally
            B._GLOBAL_OUTPUT_NAME[]=saved
        end
    end
    return (;passed=true,evidence)
end

struct DistributedWriter <: AbstractSequence_Distributed_WriterModel end
PSE.inputs_(::DistributedWriter)=NamedTuple()
PSE.outputs_(::DistributedWriter)=(signal=PSE.Distributed(PSE.Default(0.0f0)),)
function PSE.run!(::DistributedWriter,status,environment,constants,context)
    PSE.output_targets(context,(:signal,)).columns.signal .= 2.0f0
    return nothing
end
function _distributed_fixture()
    return PSE.CompositeModel(PSE.Object(0),PSE.Object(1;kind=:sequence_destination,status=(signal=0.0f0,));
        applications=(
            PSE.ModelSpec(DistributedWriter();name=:distributed,on=PSE.One(id=0),every=Hour(1),
                outputs_to=(PSE.OutputTo(PSE.Many(kind=:sequence_destination,within=PSE.SceneScope());vars=(:signal,)),)),
            PSE.ModelSpec(_C().Inferred();name=:reader,on=PSE.Many(kind=:sequence_destination),every=Hour(1)),
        ),environment=(duration=Hour(1),))
end
"""Targeted newborn initialization/temporal behavior or distributed inference."""
function sequence_feature_checks(case::Symbol=:initializer)
    N=getfield(Main,:NewbornPreparationChecks)
    if case===:distributed
        factory=_distributed_fixture
        mutate! = (model,step)->step==2 ? PSE.register_object!(model,
            PSE.Object(2;kind=:sequence_destination,status=(signal=0.0f0,))) : nothing
        steps=2
    elseif case in (:initializer,:mixed_cadence)
        cadence=case===:mixed_cadence ? Hour(2) : Hour(1)
        factory=()->N.preparation_fixture(;source_every=cadence).model
        mutate! = (model,step)->nothing
        steps=case===:mixed_cadence ? 4 : 3
    else
        throw(ArgumentError("Choose :initializer, :mixed_cadence or :distributed"))
    end
    @testset "Sequence preserves $case fallback and live binding semantics" begin
        result=_pair(factory;steps,mutate!)
        if case===:distributed
            @test PSE.model_status(result.candidate.model,2).observed===2.0f0
            @test _report(result.candidate).counters.general_inferred_groups>0
            @test _report(result.candidate).counters.ordinary_binding_dispatches>0
        end
        return (;passed=true,case,evidence=_evidence(result.candidate;before=result.before))
    end
end

function sequence_recompile_checks()
    C,B=_C(),_B()
    left,right=C._declaration_fixture(),C._declaration_fixture()
    reference=PSE.run!(left.model;steps=0,outputs=:all)
    candidate=C._prepare(right.model;enable! = _enable!,outputs=:all)
    @testset "Sequence is rebuilt for fresh dynamic declarations" begin
        previous=C._initial_pair(reference,candidate)
        for simulation in (reference,candidate)
            PSE.register_object!(simulation.model,PSE.Object(2;kind=:declaration_unit));PSE.step!(simulation)
        end
        B._state(reference,candidate,previous)
        for fixture in (left,right)
            fixture.source_port[]=fixture.reader_port[]=:beta
            PSE.Advanced.refresh_bindings!(fixture.model;force=true)
        end
        reference=PSE.run!(left.model;steps=0,outputs=:all)
        candidate=PSE.run!(right.model;steps=0,outputs=:all)
        previous=C._initial_pair(reference,candidate)
        for simulation in (reference,candidate)
            PSE.register_object!(simulation.model,PSE.Object(3;kind=:declaration_unit));PSE.step!(simulation)
            binding=only(simulation.compiled.input_bindings_by_target[(:reader,PSE.ObjectId(3))])
            @test binding.input===binding.source_var===:beta
        end
        B._state(reference,candidate,previous)
        report=_report(candidate)
        @test report.counters.programs_built>=2
        @test get(report.base_program.compile_skips,:output_declaration_effects,0)+
            get(report.base_program.compile_skips,:output_names_not_concrete,0)>0
        return (;passed=true,evidence=_evidence(candidate),qualification=:ordinary_dynamic_declaration_fallback)
    end
end

end # module
