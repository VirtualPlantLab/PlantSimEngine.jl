module TypedOutputPreparationChecks

using Dates, Test, PlantSimEngine
const PSE = PlantSimEngine
const TOP = Main.TypedOutputPreparation
export typed_output_preparation_checks

PSE.@process "typed_output_fixture" verbose=false
mutable struct EffectDefaults <: AbstractTyped_Output_FixtureModel
    value::Float32
    prototype::Vector{Float32}
    log::Vector{Symbol}
    tag::Symbol
    fail::Base.RefValue{Bool}
end
PSE.inputs_(::EffectDefaults) = NamedTuple()
function PSE.outputs_(model::EffectDefaults)
    push!(model.log,model.tag)
    model.fail[] && error("effectful output declaration failure")
    return (counter=model.value,payload=model.prototype,transient=model.prototype)
end

mutable struct MutablePlan
    id::Symbol
    spec::Any
end

function _application(model, ids; id=:outputs, slot=1, mutable_plan=false)
    spec = PSE.ModelSpec(model; name=id, on=PSE.Many(kind=:typed_output_unit),
        output_routing=(transient=:stream_only,))
    plan = mutable_plan ? MutablePlan(id,spec) : PSE.CompiledApplicationPlan(
        slot,id,spec,PSE.process(spec),id,spec.applies_to,nothing,nothing,nothing,nothing)
    return PSE.CompiledModelApplication(plan,PSE.ObjectId[PSE.ObjectId(id) for id in ids])
end

function _fixture(count; candidate=false, mutable_plan=false)
    log = Symbol[]
    declaration = EffectDefaults(3.0f0,Float32[4],log,:defaults,Ref(false))
    objects = [PSE.Object(index; kind=:typed_output_unit,
        status=index==1 ? PSE.Status(counter=17.0f0) : nothing) for index in 1:count]
    model = PSE.CompositeModel(objects...;environment=(duration=Hour(1),))
    application = _application(declaration,1:count;mutable_plan)
    empty!(log) # ModelSpec validation is outside the isolated body comparison.
    candidate && TOP.enable_typed_output_preparation!(model)
    return (;model,application,declaration,log)
end

_status(fixture,id) = PSE._model_object(fixture.model,PSE.ObjectId(id)).status
function _snapshot(fixture)
    return [(object.id,object.status===nothing ? nothing : deepcopy(NamedTuple(object.status)))
        for object in PSE.model_objects(fixture.model)]
end
_prepare(fixture) = PSE._prepare_model_output_statuses_batched!(fixture.model,Any[fixture.application])

function _outcome(fixture, applications)
    try
        PSE._prepare_model_output_statuses_batched!(fixture.model,applications)
        return nothing
    catch exception
        return (type=typeof(exception),message=sprint(showerror,exception))
    end
end

"""Isolated application-body parity, effect order, mutable defaults and fallback.

These are status-preparation checks, not scientific-kernel executions or timing
results. Downstream lifecycle/call/environment checks run through the ordinary
fixture harness separately.
"""
function typed_output_preparation_checks()
    evidence = Any[]
    @testset "Typed output application barrier preserves fresh ordinary effects" begin
        for count in (0,1,3)
            left,right = _fixture(count),_fixture(count;candidate=true)
            old_refs = count==0 ? nothing :
                (PSE.refvalue(_status(left,1),:counter),PSE.refvalue(_status(right,1),:counter))
            _prepare(left); _prepare(right)
            @test _snapshot(left) == _snapshot(right)
            @test left.log == right.log == [:defaults]
            for fixture in (left,right)
                for id in 1:count
                    status = _status(fixture,id)
                    @test status.counter isa Float32
                    @test status.payload == Float32[4]
                    @test status.payload !== fixture.declaration.prototype
                    @test !hasproperty(status,:transient)
                end
                if count>1
                    @test _status(fixture,1).payload !== _status(fixture,2).payload
                end
            end
            if count>0
                @test PSE.refvalue(_status(left,1),:counter) === old_refs[1]
                @test PSE.refvalue(_status(right,1),:counter) === old_refs[2]
                @test old_refs[1][] === old_refs[2][] === 17.0f0
            end
            before = TOP.typed_output_preparation_report(right.model)
            @test before.counters.applications_completed == 1
            @test before.counters.objects_prepared == count
            @test before.counters.canonical_ports_visited == 2count
            @test before.counters.defaults_added == (count==0 ? 0 : 2count-1)
            @test TOP.typed_output_preparation_report(left.model).counters.objects_prepared == 0
            # A later object reads current declaration data; previous fields
            # and their mutable values keep their original canonical cells.
            for fixture in (left,right)
                fixture.declaration.value = 23.0f0
                fixture.declaration.prototype[1] = 29.0f0
                PSE.register_object!(fixture.model,PSE.Object(count+1;kind=:typed_output_unit))
                push!(fixture.application.target_ids,PSE.ObjectId(count+1))
                _prepare(fixture)
                @test _status(fixture,count+1).counter === 23.0f0
                @test _status(fixture,count+1).payload == Float32[29]
                count==0 || @test _status(fixture,1).payload == Float32[4]
            end
            @test _snapshot(left) == _snapshot(right)
            @test left.log == right.log == [:defaults,:defaults]
            push!(evidence,(count,report=TOP.typed_output_preparation_report(right.model)))
        end

        left,right = _fixture(2;mutable_plan=true),_fixture(2;candidate=true,mutable_plan=true)
        _prepare(left); _prepare(right)
        @test _snapshot(left) == _snapshot(right)
        @test left.log == right.log == [:defaults]
        fallback = TOP.typed_output_preparation_report(right.model)
        @test fallback.counters.applications_completed == 0
        @test fallback.counters.declines == 1

        left,right = _fixture(2),_fixture(2;candidate=true)
        applications = Any[]
        for fixture in (left,right)
            failing = EffectDefaults(1.0f0,Float32[2],fixture.log,:failure,Ref(false))
            second = _application(failing,1:2;id=:failure,slot=2)
            failing.fail[] = true
            empty!(fixture.log)
            push!(applications,Any[fixture.application,second])
        end
        @test _outcome(left,applications[1]) == _outcome(right,applications[2])
        @test left.log == right.log == [:defaults,:failure]
        @test _snapshot(left) == _snapshot(right)
        @test all(fixture -> !hasproperty(_status(fixture,1),:payload),(left,right))
        failed = TOP.typed_output_preparation_report(right.model)
        @test failed.counters.application_attempts == 2
        @test failed.counters.applications_completed == 1
    end
    return (passed=true,evidence,scientific_kernel_execution=false,
        coverage=(:targetless_declaration,:existing_refs,:Float32,:mutable_default_privacy,
            :fresh_parameter_values,:stream_only_routing,:declaration_effect_order,
            :exception_no_replay,:unsupported_mutable_plan_fallback))
end

end # module
