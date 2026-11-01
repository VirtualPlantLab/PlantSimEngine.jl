module PersistentTightChecks

using Dates, Random, Test, PlantSimEngine
const PSE = PlantSimEngine
const Native = Main.NativePBDriver
const Shared = Main.SharedCallProgram
const Tight = Main.TightCallProgram
const CR = Main.CompiledRegionsExperiment
const F = Main.DirectPlannerFixtures

export persistent_fixture, persistent_lifecycle_checks, persistent_fallback_checks,
    persistent_public_exposure_checks, persistent_layout_checks, persistent_all_checks

# These are deliberately small generic scientific kernels. They use the
# existing audited Tight capability; growth stays in an ordinary controller.
PSE.@process "persistent_check_root" verbose=false
PSE.@process "persistent_check_child" verbose=false
PSE.@process "persistent_check_growth" verbose=false
struct PersistentRoot{T} <: AbstractPersistent_Check_RootModel end
struct PersistentChild{T,R} <: AbstractPersistent_Check_ChildModel
    rng::R
end
struct PersistentGrowth{T} <: AbstractPersistent_Check_GrowthModel
    birth::Bool
    removal::Bool
end
PSE.inputs_(::PersistentRoot{T}) where {T} =
    (tag=PSE.Required(Int),child_value=PSE.Required(T),phase_tick=PSE.Required(Int))
PSE.outputs_(::PersistentRoot{T}) where {T} = (root_value=zero(T),root_visits=0)
PSE.inputs_(::PersistentChild) = (tag=PSE.Required(Int),)
PSE.outputs_(::PersistentChild{T}) where {T} = (child_value=zero(T),child_visits=0)
PSE.inputs_(::PersistentGrowth) = NamedTuple()
PSE.outputs_(::PersistentGrowth) = (ticks=0,)

@inline function _entry!(constants, role, status, time)
    push!(constants.effects,(role,status.tag,time))
    return nothing
end
function PSE.run!(model::PersistentRoot,status,environment,constants,context)
    _entry!(constants,:root,status,constants.tick[])
    PSE.run_call!(context,:child;sampled_environment=environment,publish=false)
    status.root_value += status.child_value
    status.root_visits += 1
    push!(constants.effects,(:root_value,status.tag,constants.tick[],status.root_value))
    return nothing
end
function PSE.run!(model::PersistentChild{T},status,environment,constants,context) where {T}
    _entry!(constants,:child,status,constants.tick[])
    status.child_value += rand(model.rng,T)
    status.child_visits += 1
    push!(constants.effects,(:child_value,status.tag,constants.tick[],status.child_value))
    return nothing
end
function PSE.run!(model::PersistentGrowth{T},status,environment,constants,context) where {T}
    status.ticks += 1
    if model.birth && status.ticks == 2
        PSE.register_object!(PSE.runtime_model(context),_unit(3,T))
        push!(constants.effects,(:birth,3,context.time))
    elseif model.removal && status.ticks == 3
        PSE.remove_object!(PSE.runtime_model(context),1)
        push!(constants.effects,(:remove,1,context.time))
    end
    return nothing
end
for Model in (PersistentRoot,PersistentChild)
    @eval Native.native_call_effects(::Type{<:$Model}) = :fixed_native_calls
    @eval Native.direct_status_compatible(::Type{<:$Model}) = true
    @eval Shared.shared_context_effects(::Type{<:$Model}) = :synchronous_borrowed_context
    @eval Tight.tight_call_effects(::Type{<:$Model}) = Tight._TIGHT_CAPABILITY
end

_unit(id,::Type{T};kind=:persistent_growing,extra=false) where {T} =
    PSE.Object(id;kind,status=extra ?
        (tag=id,root_value=zero(T),root_visits=0,child_value=zero(T),child_visits=0,extra_marker=:new_layout) :
        (tag=id,root_value=zero(T),root_visits=0,child_value=zero(T),child_visits=0))

"""Two independent scalar hard-call regions; only one changes membership."""
function persistent_fixture(;T=Float32,birth=true,removal=true)
    child=PersistentChild{T,Random.MersenneTwister}(Random.MersenneTwister(174))
    stable_child=PersistentChild{T,Random.MersenneTwister}(Random.MersenneTwister(219))
    return PSE.CompositeModel(PSE.Object(:controller),_unit(1,T),_unit(2,T),
        _unit(100,T;kind=:persistent_stable);
        applications=(
            PSE.ModelSpec(PersistentGrowth{T}(birth,removal);name=:growth,
                on=PSE.One(id=:controller),every=Hour(1)),
            PSE.ModelSpec(PersistentRoot{T}();name=:root,
                on=PSE.Many(kind=:persistent_growing),every=Hour(1),
                inputs=(child_value=PSE.One(within=PSE.Self(),application=:child,var=:child_value),
                    phase_tick=PSE.One(id=:controller,within=PSE.SceneScope(),application=:growth,var=:ticks)),
                calls=(child=PSE.One(within=PSE.Self(),application=:child),)),
            PSE.ModelSpec(child;name=:child,on=PSE.Many(kind=:persistent_growing),every=Hour(1)),
            PSE.ModelSpec(PersistentRoot{T}();name=:stable_root,
                on=PSE.Many(kind=:persistent_stable),every=Hour(1),
                inputs=(child_value=PSE.One(within=PSE.Self(),application=:stable_child,var=:child_value),
                    phase_tick=PSE.One(id=:controller,within=PSE.SceneScope(),application=:growth,var=:ticks)),
                calls=(child=PSE.One(within=PSE.Self(),application=:stable_child),)),
            PSE.ModelSpec(stable_child;name=:stable_child,
                on=PSE.Many(kind=:persistent_stable),every=Hour(1)),
        ),environment=(duration=Hour(1),))
end

_constants() = (effects=Any[],tick=Ref(0))
_PT() = getfield(Main,:PersistentTightProgram)
_report(simulation) = _PT().persistent_tight_report(simulation)
_regions(simulation) = _PT().persistent_regions(simulation)

Base.@nospecializeinfer @noinline function _prepare(model,constants;candidate=false,outputs=:all)
    @nospecialize model constants
    if candidate
        return Base.invokelatest(_PT().prepare_persistent_tight,model;
            steps=0,outputs,constants,count_calls=true,state_strategy=:references)
    end
    return PSE.run!(model;steps=0,outputs,constants)
end

function _science_equal(reference,candidate,left,right)
    @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
    @test isequal(F.snapshot(candidate,:generic),F.snapshot(reference,:generic))
    @test isequal(F.scientific_rngs(candidate.model),F.scientific_rngs(reference.model))
    @test isequal(right.effects,left.effects)
    return nothing
end

function _identity_parity(old_left,old_right,reference,candidate)
    new_left,new_right=F.identities(reference.model),F.identities(candidate.model)
    @test F.same_identity_transitions(old_left,old_right,new_left,new_right)
    @test keys(new_left.statuses)==keys(new_right.statuses)
    for key in keys(new_left.statuses)
        @test typeof(new_left.statuses[key])===typeof(new_right.statuses[key])
        @test new_left.statuses[key] !== new_right.statuses[key]
    end
    for key in keys(new_left.references)
        @test typeof(new_left.references[key])===typeof(new_right.references[key])
        @test new_left.references[key] !== new_right.references[key]
    end
    return new_left,new_right
end

function _region_map(simulation)
    rows=[row for row in _regions(simulation) if row.active]
    @test length(unique(row.application for row in rows))==length(rows)
    return Dict(row.application=>row for row in rows)
end

function _step_pair!(reference,candidate,left,right,tick)
    left.tick[]=right.tick[]=tick
    PSE.step!(reference)
    PSE.step!(candidate)
    _science_equal(reference,candidate,left,right)
    return nothing
end

"""Same-schema births/removals keep executing the private numeric program."""
function persistent_lifecycle_checks(;T=Float32,outputs_modes=(:none,:all))
    reports=Any[]
    @testset "Persistent typed scalar calls through live birth and removal" begin
        for outputs in outputs_modes
            left,right=_constants(),_constants()
            reference=Base.invokelatest(_prepare,persistent_fixture(;T),left;outputs)
            candidate=Base.invokelatest(_prepare,persistent_fixture(;T),right;candidate=true,outputs)
            _science_equal(reference,candidate,left,right)
            old_left,old_right=F.identities(reference.model),F.identities(candidate.model)
            escaped_status=PSE.model_status(candidate.model,2)
            escaped_ref=PSE.refvalue(escaped_status,:root_value)
            initial_regions=_region_map(candidate)
            @test haskey(initial_regions,:root)
            @test haskey(initial_regions,:stable_root)
            root_signature=initial_regions[:root].numerical_signature
            stable_signature=initial_regions[:stable_root].numerical_signature
            stable_identity=initial_regions[:stable_root].identity
            phases=Any[]
            previous=_report(candidate)
            for (tick,expected_roots) in enumerate((3,4,3,3))
                _step_pair!(reference,candidate,left,right,tick)
                old_left,old_right=_identity_parity(old_left,old_right,reference,candidate)
                @test PSE.model_status(candidate.model,2)===escaped_status
                @test PSE.refvalue(escaped_status,:root_value)===escaped_ref
                current=_report(candidate)
                @test current.executed_numerical_roots-previous.executed_numerical_roots==expected_roots
                @test current.executed_numerical_calls-previous.executed_numerical_calls==expected_roots
                regions=_region_map(candidate)
                @test regions[:root].numerical_signature===root_signature
                @test regions[:stable_root].numerical_signature===stable_signature
                @test regions[:stable_root].identity===stable_identity
                @test Set(regions[:root].row_ids)==Set(PSE.ObjectId.(tick==1 ? (1,2) : tick==2 ? (1,2,3) : (2,3)))
                @test Set(regions[:stable_root].row_ids)==Set((PSE.ObjectId(100),))
                @test regions[:root].active && regions[:stable_root].active
                @test !regions[:root].exposed && !regions[:stable_root].exposed
                @test PSE.model_status(candidate.model,2).root_visits==tick
                if tick>=2
                    @test PSE.model_status(candidate.model,3).root_visits==tick-1
                end
                if tick>=3
                    @test !any(object->object.id==PSE.ObjectId(1),PSE.model_objects(candidate.model))
                end
                push!(phases,(tick=tick,expected_roots=expected_roots,report=current))
                previous=current
            end
            push!(reports,(T=string(T),outputs=outputs,phases=phases,
                unchanged_stable_region_identity=true,same_schema_numerical_signatures_unchanged=true,
                signature_scope=:exact_numeric_entry_types_not_a_MethodInstance_or_codecache_claim))
        end
    end
    return (passed=true,reports=reports)
end

function _root_owner(simulation,application)
    group=only(group for group in simulation.execution_plan.groups if group.application.id==application)
    return first(first(group.batches).targets)
end

function _public_target_metadata(target)
    return (target_time=target.time,target_publication_allowed=target.publication_allowed,
        application=target.application.id,object_id=target.object_id,
        context_time=target.execution_target.context.time,
        context_publication_allowed=target.execution_target.context.publication_allowed)
end
function _public_metadata(targets)
    return (time=targets.time,publication_allowed=targets.publication_allowed,
        target=_public_target_metadata(only(targets)))
end

"""Public target exposure is observable across later refreshes and time."""
function persistent_public_exposure_checks()
    left,right=_constants(),_constants()
    reference=Base.invokelatest(_prepare,persistent_fixture(;removal=false),left;outputs=:all)
    candidate=Base.invokelatest(_prepare,persistent_fixture(;removal=false),right;
        candidate=true,outputs=:all)
    @testset "Exposed public call metadata survives persistent refresh" begin
        # Materializing targets is intentional here. The normal lifecycle gate
        # obtains identity/signature records without touching public owners.
        left_owner,right_owner=_root_owner(reference,:root),_root_owner(candidate,:root)
        saved_left=PSE.call_targets(left_owner.context,:child)
        saved_right=PSE.call_targets(right_owner.context,:child)
        saved_left_view,saved_right_view=only(saved_left),only(saved_right)
        saved_left_ref=PSE.refvalue(only(saved_left).canonical_status,:child_value)
        saved_right_ref=PSE.refvalue(only(saved_right).canonical_status,:child_value)
        @test isequal(_public_metadata(saved_right),_public_metadata(saved_left))
        phases=Any[]
        for tick in 1:3
            _step_pair!(reference,candidate,left,right,tick)
            @test isequal(_public_metadata(saved_right),_public_metadata(saved_left))
            @test isequal(_public_target_metadata(saved_right_view),_public_target_metadata(saved_left_view))
            @test PSE.refvalue(saved_left_view.canonical_status,:child_value)===saved_left_ref
            @test PSE.refvalue(saved_right_view.canonical_status,:child_value)===saved_right_ref
            @test PSE.refvalue(only(saved_left).canonical_status,:child_value)===saved_left_ref
            @test PSE.refvalue(only(saved_right).canonical_status,:child_value)===saved_right_ref
            current_left=PSE.call_targets(_root_owner(reference,:root).context,:child)
            current_right=PSE.call_targets(_root_owner(candidate,:root).context,:child)
            @test isequal(_public_metadata(current_right),_public_metadata(current_left))
            @test only(current_right).canonical_status===PSE.model_status(candidate.model,1)
            # Public exposure may conservatively disable the whole application
            # or just this row. Either policy must keep that exposed row out of
            # all active optimized regions, even after the birth refresh.
            @test all(row->!(row.application==:root && row.active &&
                PSE.ObjectId(1) in row.row_ids),_regions(candidate))
            push!(phases,(tick=tick,report=_report(candidate),metadata=_public_metadata(saved_right)))
        end
        return (passed=true,phases=phases,scope=:public_exposure_ordinary_metadata_and_canonical_refs)
    end
end

"""An unaudited full call protocol must remain on the ordinary fallback."""
function persistent_fallback_checks()
    DirectChecks=Main.DirectCallCompilerChecks
    left,right=(capture=Any[],),(capture=Any[],)
    reference=Base.invokelatest(_prepare,DirectChecks._retained_fixture(false),left;outputs=:all)
    candidate=Base.invokelatest(_prepare,DirectChecks._retained_fixture(false),right;
        candidate=true,outputs=:all)
    @testset "Persistent program preserves unsupported retained-call semantics" begin
        previous=_report(candidate)
        for _ in 1:3
            PSE.step!(reference);PSE.step!(candidate)
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            @test isequal(F.snapshot(candidate,:generic),F.snapshot(reference,:generic))
            @test only(right.capture) isa PSE.CallTargets
        end
        current=_report(candidate)
        @test current.executed_numerical_roots==previous.executed_numerical_roots==0
        @test isequal(_public_metadata(only(right.capture)),_public_metadata(only(left.capture)))
        return (passed=true,report=current,scope=:retained_results_and_public_reexecution_ordinary_fallback)
    end
end

"""A new canonical field layout is admitted freshly or falls back safely."""
function persistent_layout_checks()
    left,right=_constants(),_constants()
    reference=Base.invokelatest(_prepare,persistent_fixture(;birth=false,removal=false),left;outputs=:all)
    candidate=Base.invokelatest(_prepare,persistent_fixture(;birth=false,removal=false),right;
        candidate=true,outputs=:all)
    @testset "Unseen status layout cannot reuse stale rows" begin
        _step_pair!(reference,candidate,left,right,1)
        old_left,old_right=F.identities(reference.model),F.identities(candidate.model)
        before=_report(candidate)
        for simulation in (reference,candidate)
            PSE.register_object!(simulation.model,_unit(3,Float32;extra=true))
        end
        _step_pair!(reference,candidate,left,right,2)
        _identity_parity(old_left,old_right,reference,candidate)
        @test PSE.model_status(candidate.model,3).extra_marker===:new_layout
        @test PSE.model_status(candidate.model,3).root_visits==1
        @test PSE.model_status(candidate.model,3).child_visits==1
        after=_report(candidate)
        delta=after.executed_numerical_roots-before.executed_numerical_roots
        # The stable independent region remains eligible. This gate imposes no
        # optimization promise on an undeclared status shape: fresh admission,
        # per-row fallback, or whole changed-region fallback are all valid.
        @test 1<=delta<=4
        return (passed=true,report=after,optimized_roots_after_new_layout=delta,
            scope=:fresh_admission_or_ordinary_fallback_with_exact_state_history_rng_refs)
    end
end

function persistent_all_checks(;T=Float32)
    return (lifecycle=persistent_lifecycle_checks(;T),
        public_exposure=persistent_public_exposure_checks(),fallback=persistent_fallback_checks(),
        unseen_layout=persistent_layout_checks())
end

end # module
