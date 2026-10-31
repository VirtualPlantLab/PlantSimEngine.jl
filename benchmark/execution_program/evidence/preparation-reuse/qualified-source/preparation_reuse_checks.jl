module PreparationReuseChecks

using Dates, Test, PlantSimEngine
const PSE=PlantSimEngine
const Harness=Main.PreparationReuseMeasurements
const PB=Main.NativePBDriver
const XP=Main.NativeXPDriver
const CR=Main.CompiledRegionsExperiment
const CANDIDATE_ARMS=(:plan_view_reuse,:bounded_preparation,:combined)

export preparation_pb_checks, preparation_xp_checks, preparation_identity_checks,
    preparation_factorial_checks

function _identities(model)
    statuses=Dict{PSE.ObjectId,Any}()
    cells=Dict{Tuple{PSE.ObjectId,Symbol},Any}()
    for object in PSE.model_objects(model)
        status=object.status
        statuses[object.id]=status
        for name in propertynames(status)
            cells[(object.id,name)]=PSE.refvalue(status,name)
        end
    end
    return (;statuses,cells)
end

function _same_identity_transitions(before_left,before_right,after_left,after_right)
    @test Set(keys(after_left.statuses))==Set(keys(after_right.statuses))
    @test Set(keys(after_left.cells))==Set(keys(after_right.cells))
    for id in intersect(Set(keys(before_left.statuses)),Set(keys(after_left.statuses)))
        @test (after_right.statuses[id]===before_right.statuses[id])===
            (after_left.statuses[id]===before_left.statuses[id])
    end
    for key in intersect(Set(keys(before_left.cells)),Set(keys(after_left.cells)))
        @test (after_right.cells[key]===before_right.cells[key])===
            (after_left.cells[key]===before_left.cells[key])
    end
    return nothing
end

_xp_snapshot(simulation)=(scientific=XP.xp_portable_snapshot(simulation),
    topology=sort!([(id=repr(object.id.value),parent=repr(object.parent),
        kind=repr(object.kind),scale=repr(object.scale),geometry=repr(PSE.geometry(object)))
        for object in PSE.model_objects(simulation.model)];by=row->row.id))

function preparation_pb_checks(;nobjects=2,steps=2,outputs=:all,arms=CANDIDATE_ARMS)
    reports=Any[]
    @testset "PB preparation factorial: full state/history and independent canonical refs" begin
        for arm in arms
            left=PB.pb_native_fixture(;native=false,nobjects,steps)
            right=PB.pb_native_fixture(;native=false,nobjects,steps)
            reference=PSE.run!(left.model;steps=0,outputs)
            candidate=Harness.prepare_arm(right.model,arm;steps=0,outputs)
            @test isequal(CR.portable_downstream_snapshot(candidate),
                CR.portable_downstream_snapshot(reference))
            before_left,before_right=_identities(left.model),_identities(right.model)
            for key in keys(before_left.cells)
                @test before_left.cells[key] !== before_right.cells[key]
            end
            for _ in 1:steps
                PSE.step!(reference);PSE.step!(candidate)
                @test isequal(CR.portable_downstream_snapshot(candidate),
                    CR.portable_downstream_snapshot(reference))
                after_left,after_right=_identities(left.model),_identities(right.model)
                _same_identity_transitions(before_left,before_right,after_left,after_right)
                before_left,before_right=after_left,after_right
            end
            @test CR.downstream_work_report(candidate,PSE.object_ids(right.model))==
                CR.downstream_work_report(reference,PSE.object_ids(left.model))
            coverage=Harness.preparation_coverage(candidate,arm)
            @test coverage.driver_units==coverage.native_fields==coverage.native_driver_units==0
            push!(reports,(;arm,coverage))
        end
    end
    return (;passed=true,reports)
end

function preparation_xp_checks(;steps=4,outputs=:all,arms=CANDIDATE_ARMS)
    weather=CR._xpalm_fixture_weather(steps)
    reports=Any[]
    @testset "XP preparation factorial: growth, full history, topology and Ref transitions" begin
        for arm in arms
            left=XP.xpalm_native_fixture(;steps,weather,native=false)
            right=XP.xpalm_native_fixture(;steps,weather,native=false)
            reference=PSE.run!(left;steps=0,outputs)
            candidate=Harness.prepare_arm(right,arm;steps=0,outputs)
            left_initial,right_initial=collect(PSE.object_ids(left)),collect(PSE.object_ids(right))
            @test isequal(_xp_snapshot(candidate),_xp_snapshot(reference))
            before_left,before_right=_identities(left),_identities(right)
            for _ in 1:steps
                PSE.step!(reference);PSE.step!(candidate)
                @test isequal(_xp_snapshot(candidate),_xp_snapshot(reference))
                after_left,after_right=_identities(left),_identities(right)
                _same_identity_transitions(before_left,before_right,after_left,after_right)
                before_left,before_right=after_left,after_right
            end
            expected=CR.downstream_work_report(reference,left_initial)
            work=CR.downstream_work_report(candidate,right_initial)
            @test work==expected
            @test length(work.added_ids)>=3
            @test candidate.model.status_storage===nothing
            coverage=Harness.preparation_coverage(candidate,arm)
            @test coverage.driver_units==coverage.native_fields==coverage.native_driver_units==0
            push!(reports,(;arm,work,coverage))
        end
    end
    return (;passed=true,reports,
        interpretation=:accelerated_growth_fixture_not_biological_validation)
end

PSE.@process "preparation_identity_root" verbose=false
PSE.@process "preparation_identity_reader" verbose=false
PSE.@process "preparation_identity_source" verbose=false
struct IdentityRoot <: AbstractPreparation_Identity_RootModel end
struct IdentityReader <: AbstractPreparation_Identity_ReaderModel end
struct IdentitySource <: AbstractPreparation_Identity_SourceModel end
PSE.inputs_(::IdentityRoot)=NamedTuple()
PSE.outputs_(::IdentityRoot)=(root_visits=0,)
PSE.inputs_(::IdentityReader)=(signals=PSE.Required(Vector{Float32}),)
PSE.outputs_(::IdentityReader)=(total=0.0f0,reader_visits=0)
PSE.inputs_(::IdentitySource)=NamedTuple()
PSE.outputs_(::IdentitySource)=(value=0.0f0,source_visits=0)
function PSE.run!(::IdentityRoot,status,environment,constants,context)
    targets=PSE.run_call!(context,:readers;publish=true)
    isempty(constants.saved) && push!(constants.saved,targets)
    hasproperty(constants,:current) && push!(constants.current,targets)
    status.root_visits+=1
    return nothing
end
function PSE.run!(::IdentityReader,status,environment,constants,context)
    status.total=sum(PSE.bound_input(context,:signals);init=0.0f0)
    status.reader_visits+=1
    return nothing
end
function PSE.run!(::IdentitySource,status,environment,constants,context)
    status.source_visits+=1
    return nothing
end

function _identity_fixture()
    return PSE.CompositeModel(
        PSE.Object(:root),PSE.Object(:reader;kind=:identity_reader),
        PSE.Object(:source_1;kind=:identity_source,status=(value=1.0f0,));
        applications=(
            PSE.ModelSpec(IdentityRoot();name=:root,on=PSE.One(id=:root),every=Hour(1),
                calls=(readers=PSE.Many(kind=:identity_reader,within=PSE.SceneScope(),
                    application=:reader),)),
            PSE.ModelSpec(IdentityReader();name=:reader,on=PSE.Many(kind=:identity_reader),
                every=Hour(1),inputs=(signals=PSE.Many(kind=:identity_source,
                    within=PSE.SceneScope(),application=:source,var=:value),)),
            PSE.ModelSpec(IdentitySource();name=:source,on=PSE.Many(kind=:identity_source),
                every=Hour(1)),
        ),environment=(duration=Hour(1),))
end

"""Affected application-local views get a fresh Status token as in ordinary PSE.

Saving the genuine collection AND an individual CallTarget distinguishes local
status identity from canonical model_status identity. The default structural
transition adds a source and reparents an existing source, exercising ordinary
preservation for genuinely affected keys. Its reader's Many carrier can still
extend in place, so the oracle determines which existing local views change.
Monotonic homogeneous append can legitimately leave a view unaffected. Public
force=true recompilation deliberately skips preservation, so that optional
transition checks parity without claiming preserved-view work. Saved collections
may retain their old epoch; the current call result is checked separately.
"""
function preparation_identity_checks(;arms=CANDIDATE_ARMS,consume_refresh=false,
    transition=:structural_rewire)
    transition in (:structural_rewire,:force_refresh) ||
        throw(ArgumentError("Unknown identity transition: $transition"))
    reports=Any[]
    @testset "Preparation reuse preserves affected local-view and saved-target identity epochs" begin
        for arm in arms
            left,right=(saved=Any[],current=Any[],),(saved=Any[],current=Any[],)
            reference=PSE.run!(_identity_fixture();steps=0,outputs=:all,constants=left)
            candidate=Harness.prepare_arm(_identity_fixture(),arm;
                steps=0,outputs=:all,constants=right)
            PSE.step!(reference);PSE.step!(candidate)
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            left_saved,right_saved=only(left.saved),only(right.saved)
            left_target,right_target=only(left_saved),only(right_saved)
            left_view=reference.compiled.status_views_by_target[(:reader,PSE.ObjectId(:reader))]
            right_view=candidate.compiled.status_views_by_target[(:reader,PSE.ObjectId(:reader))]
            left_local,right_local=left_view.status,right_view.status
            left_target_local,right_target_local=left_target.status,right_target.status
            old_left_views=copy(reference.compiled.status_views_by_target)
            old_right_views=copy(candidate.compiled.status_views_by_target)
            left_cell=PSE.refvalue(PSE.model_status(reference.model,:reader),:total)
            right_cell=PSE.refvalue(PSE.model_status(candidate.model,:reader),:total)
            @test left_target_local===left_local
            @test right_target_local===right_local
            for simulation in (reference,candidate)
                PSE.register_object!(simulation.model,PSE.Object(:source_2;
                    kind=:identity_source,status=(value=2.0f0,)))
                if transition===:structural_rewire
                    PSE.reparent_object!(simulation.model,:source_1,:root)
                else
                    PSE.refresh_bindings!(simulation.model;force=true)
                end
                if consume_refresh
                    PSE.refresh_bindings!(simulation.model)
                    PSE.refresh_environment_bindings!(simulation.model)
                end
            end
            PSE.step!(reference);PSE.step!(candidate)
            @test isequal(CR.downstream_fingerprint(candidate),CR.downstream_fingerprint(reference))
            new_left=reference.compiled.status_views_by_target[(:reader,PSE.ObjectId(:reader))]
            new_right=candidate.compiled.status_views_by_target[(:reader,PSE.ObjectId(:reader))]
            common=intersect(Set(keys(old_left_views)),
                Set(keys(reference.compiled.status_views_by_target)))
            @test Set(keys(reference.compiled.status_views_by_target))==
                Set(keys(candidate.compiled.status_views_by_target))
            transitions=Any[]
            for key in sort!(collect(common);by=repr)
                prior_left,prior_right=old_left_views[key],old_right_views[key]
                after_left=reference.compiled.status_views_by_target[key]
                after_right=candidate.compiled.status_views_by_target[key]
                left_changed=after_left.status !== prior_left.status
                right_changed=after_right.status !== prior_right.status
                @test right_changed===left_changed
                @test (after_right===prior_right)===(after_left===prior_left)
                @test (after_right.canonical_status===prior_right.canonical_status)===
                    (after_left.canonical_status===prior_left.canonical_status)
                for name in intersect(Set(propertynames(prior_left.status)),
                    Set(propertynames(after_left.status)))
                    @test (PSE.refvalue(after_right.status,name)===
                        PSE.refvalue(prior_right.status,name))===
                        (PSE.refvalue(after_left.status,name)===
                        PSE.refvalue(prior_left.status,name))
                end
                push!(transitions,(key=repr(key),ordinary_local_status_changed=left_changed,
                    candidate_local_status_changed=right_changed))
            end
            if transition===:structural_rewire
                @test any(row->row.ordinary_local_status_changed,transitions)
                @test any(row->row.candidate_local_status_changed,transitions)
            end
            @test (new_right===right_view)===(new_left===left_view)
            @test PSE.refvalue(PSE.model_status(reference.model,:reader),:total)===left_cell
            @test PSE.refvalue(PSE.model_status(candidate.model,:reader),:total)===right_cell
            @test only(left.saved)===left_saved
            @test only(right.saved)===right_saved
            current_left,current_right=only(left_saved),only(right_saved)
            @test (current_right.status===new_right.status)===
                (current_left.status===new_left.status)
            @test (current_right===right_target)===(current_left===left_target)
            @test (right_target.status===right_target_local)===
                (left_target.status===left_target_local)
            @test current_right.time==current_left.time
            live_left,live_right=only(last(left.current)),only(last(right.current))
            @test live_left.status===new_left.status
            @test live_right.status===new_right.status
            @test live_right.time==live_left.time==2.0
            left_many,right_many=new_left.bound_inputs.signals,new_right.bound_inputs.signals
            @test collect(PSE.object_ids(right_many))==collect(PSE.object_ids(left_many))==
                PSE.ObjectId[PSE.ObjectId(:source_1),PSE.ObjectId(:source_2)]
            @test collect(right_many)==collect(left_many)==Float32[1,2]
            @test PSE.model_status(candidate.model,:reader).total===3.0f0
            coverage=Harness.preparation_coverage(candidate,arm)
            if transition===:structural_rewire && arm in (:plan_view_reuse,:combined)
                @test coverage.reuse.plain_preservations>0
            end
            push!(reports,(;arm,consume_refresh,transition,coverage,view_transitions=transitions,
                saved_collection_time=current_right.time,current_collection_time=live_right.time,
                ordinary_saved_target_status_changed=left_target.status !== left_target_local,
                candidate_saved_target_status_changed=right_target.status !== right_target_local))
        end
    end
    return (;passed=true,reports)
end

function preparation_factorial_checks(;arms=CANDIDATE_ARMS)
    return (pb=preparation_pb_checks(;arms),
        identity=preparation_identity_checks(;arms),
        xp=preparation_xp_checks(;arms))
end

end
