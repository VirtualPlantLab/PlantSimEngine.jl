# Standalone focused driver; existing Kaimon sessions may already own the modules.
isdefined(Main, :ReusableProgram) || include(joinpath(@__DIR__, "app", "src", "program.jl"))
isdefined(Main, :FullXPalmFixture) || include(joinpath(@__DIR__, "app", "src", "full_xpalm_fixture.jl"))

module FullXPalmChecks

using Test
using PlantSimEngine
using XPalm
import MultiScaleTreeGraph as MTG
import ..ReusableProgram as RP
import ..FullXPalmFixture as XF
const PSE = PlantSimEngine

# Only topology is reconstructed. Scientific initial values come from the
# original XPalm policy and are supplied separately as typed per-object data.
function native_tree(descriptor)
    isempty(descriptor) && throw(ArgumentError("empty topology descriptor"))
    firstrow = first(descriptor)
    isnothing(firstrow.parent) || throw(ArgumentError("descriptor must start with its root"))
    encoding = MTG.NodeMTG(firstrow.link, firstrow.scale, firstrow.index, firstrow.level)
    attrs = NamedTuple()
    N = MTG.Node{typeof(encoding),typeof(attrs)}
    root = N(firstrow.id, nothing, N[], encoding, attrs, nothing)
    nodes = Dict{Int,N}(firstrow.id => root)
    for row in descriptor[2:end]
        haskey(nodes, row.id) && throw(ArgumentError("duplicate topology ID"))
        isnothing(row.parent) && throw(ArgumentError("multiple topology roots"))
        haskey(nodes, row.parent) || throw(ArgumentError("topology must be parent-first"))
        node = N(row.id, nothing, N[],
            MTG.NodeMTG(row.link, row.scale, row.index, row.level), attrs, nothing)
        MTG.addchild!(nodes[row.parent], node)
        nodes[row.id] = node
    end
    return root
end

_plain(value::AbstractArray) = map(_plain, collect(value))
_plain(value) = deepcopy(value)
function _status_values(status, variables)
    names = Tuple(name for name in variables if name !== :node && name in keys(status))
    return NamedTuple{names}(map(name -> _plain(status[name]), names))
end

function snapshot(state, variables)
    rows = NamedTuple[]
    for cohort in state.cohorts, row in eachindex(cohort.ids)
        node = cohort.nodes[row]
        parent = MTG.parent(node)
        category = RP._cohort_key(cohort)
        push!(rows, (
            object_id=ObjectId(cohort.ids[row]),
            parent_id=isnothing(parent) ? nothing : ObjectId(MTG.node_id(parent)),
            scale=category, link=MTG.link(node), index=MTG.index(node),
            status=_status_values(cohort.rows[row], variables[category]),
        ))
    end
    return sort!(rows; by=row -> row.object_id.value)
end

# Preserve symbolic/integer/identity equality. Floating values are compared with
# a tight tolerance; owned arrays and live carriers compare element by element.
_equal(a, b) = isequal(a, b)
_equal(a::AbstractFloat, b::AbstractFloat) = typeof(a) === typeof(b) &&
    (isequal(a, b) || isapprox(a, b; rtol=1e-12, atol=1e-12))
function _equal(a::AbstractArray, b::AbstractArray)
    return axes(a) == axes(b) && all(_equal(x, y) for (x, y) in zip(a, b))
end
function _equal(a::NamedTuple, b::NamedTuple)
    return keys(a) == keys(b) && all(_equal(x, y) for (x, y) in zip(values(a), values(b)))
end

function _compare_objects(actual, expected)
    actual_by_id = Dict(row.object_id => row for row in actual)
    expected_by_id = Dict(row.object_id => row for row in expected)
    @test Set(keys(actual_by_id)) == Set(keys(expected_by_id))
    for id in intersect(Set(keys(actual_by_id)), Set(keys(expected_by_id)))
        left = actual_by_id[id]
        right = expected_by_id[id]
        @test (left.parent_id, left.scale, left.link, left.index) ==
              (right.parent_id, right.scale, right.link, right.index)
        @test keys(left.status) == keys(right.status)
        for variable in intersect(Set(keys(left.status)), Set(keys(right.status)))
            @testset "object $(id.value), $(variable)" begin
                @test _equal(left.status[variable], right.status[variable])
            end
        end
    end
    return nothing
end

const SampleKey = Tuple{Symbol,Int,Symbol,Int}
function native_samples(state)
    result = Dict{SampleKey,Any}()
    for application in state.applications, (variable, stream) in pairs(application.streams)
        for sample in stream.retained
            key = (sample.application, sample.object_id, variable, sample.step)
            @test !haskey(result, key)
            result[key] = _plain(sample.value)
        end
    end
    return result
end
function ordinary_samples(simulation)
    result = Dict{SampleKey,Any}()
    for sample in PSE.collect_outputs(simulation; sink=nothing)
        key = (sample.application_id, ObjectId(sample.object_id).value, sample.variable, sample.timestep)
        @test !haskey(result, key)
        result[key] = _plain(sample.value)
    end
    return result
end
function _compare_samples(actual, expected; step=nothing)
    selected(dict) = Set(key for key in keys(dict) if isnothing(step) || key[4] == step)
    actual_keys = selected(actual)
    expected_keys = selected(expected)
    @test actual_keys == expected_keys
    for key in intersect(actual_keys, expected_keys)
        @testset "output $(key)" begin
            @test _equal(actual[key], expected[key])
        end
    end
    return nothing
end

_rng_fields(model) = Tuple(name for name in (:rng, :random_generator) if hasfield(typeof(model), name))
function _scalar_draw_count(before, after; limit=10_000)
    # Original SexDetermination and AbortionRate each use scalar rand(rng).
    # Replaying a COPY until its entire RNG state matches counts actual draws;
    # it neither alters the simulation RNG nor infers draws from organ counts.
    probe = copy(before)
    for draws in 0:limit
        probe == after && return draws
        draws == limit || XPalm.Random.rand(probe)
    end
    return missing
end
function draw_counts(before, after, applications)
    counts = NamedTuple[]
    for i in eachindex(before), field in _rng_fields(before[i])
        count = _scalar_draw_count(getfield(before[i], field), getfield(after[i], field))
        @test !ismissing(count)
        push!(counts, (application=applications[i].name, field=field, draws=count))
    end
    return counts
end

function _event_counts(state)
    sexes = Symbol[]
    for cohort in state.cohorts
        RP._cohort_key(cohort) === :Phytomer || continue
        for status in cohort.rows
            :sex in keys(status) && push!(sexes, status.sex)
        end
    end
    return (
        male_objects=count(node -> MTG.symbol(node) === :Male, values(state.nodes)),
        female_objects=count(node -> MTG.symbol(node) === :Female, values(state.nodes)),
        male_phytomers=count(==(:Male), sexes),
        female_phytomers=count(==(:Female), sexes),
        undetermined_phytomers=count(==(:undetermined), sexes),
    )
end

"""Compare the complete original graph, every state/stream, and RNG after each step.
Event counts are returned as observations; no reproductive event is asserted
until an executed case establishes what the seeded scientific kernels did.
"""
function compare_case(; days=3, rate=0.05, reproductive=false, sex_seed=1,
                      abortion_seed=1, retain=true, initiation_age=0,
                      flowering=30.0, abortion_duration=6.0, sex_duration=12.0)
    settings = (; rate, reproductive, sex_seed, abortion_seed, initiation_age,
        flowering, abortion_duration, sex_duration)
    setup = XF.authoring(; settings...)
    reference_setup = XF.authoring(; settings...)
    forcing = XF.rows(days)
    program = RP.prepare(XF.preparation_scene(setup); initial=setup.initial.templates)
    kernels = deepcopy(setup.models)
    caller_rng_before = XF.rng_fingerprint(kernels)
    root = native_tree(setup.topology)
    state = RP.instantiate(program, kernels, root;
        initial=setup.initial.templates, objects=setup.initial.objects, retain)
    owned_models = map(application -> application.model, state.applications)
    before_rng = deepcopy(owned_models)
    original_model = XF.scene(reference_setup.palm, forcing;
        applications=reference_setup.applications)
    ordinary = PSE.run!(original_model; steps=0, outputs=:all)
    @test length(state.applications) == length(reference_setup.applications)
    @test map(application -> application.recipe.name, state.applications) ==
        map(application -> application.name, reference_setup.applications)
    _compare_objects(snapshot(state, setup.variables),
        XF.fingerprint(PSE.runtime_model(ordinary), reference_setup.variables))
    @test XF.rng_fingerprint(owned_models) == XF.rng_fingerprint(XF.models(PSE.runtime_model(ordinary).applications))
    for (step, row) in enumerate(forcing)
        RP.step!(state, row; constants=PSE.Constants())
        PSE.step!(ordinary)
        @test state.step == PSE.current_step(ordinary)
        _compare_objects(snapshot(state, setup.variables),
            XF.fingerprint(PSE.runtime_model(ordinary), reference_setup.variables))
        @test XF.rng_fingerprint(owned_models) == XF.rng_fingerprint(XF.models(PSE.runtime_model(ordinary).applications))
        if retain
            _compare_samples(native_samples(state), ordinary_samples(ordinary); step)
        else
            @test all(application -> all(stream -> isempty(stream.retained), values(application.streams)), state.applications)
        end
        @test isempty(state.pending)
        @test state.active_slot == 0
    end
    actual_samples = native_samples(state)
    retain && _compare_samples(actual_samples, ordinary_samples(ordinary))
    # Use actual original model instances owned by the runtime for RNG evidence.
    original_kernels = XF.models(PSE.runtime_model(ordinary).applications)
    actual_draws = draw_counts(before_rng, owned_models, setup.applications)
    original_draws = draw_counts(before_rng, original_kernels, setup.applications)
    @test actual_draws == original_draws
    @test XF.rng_fingerprint(kernels) == caller_rng_before
    return (
        applications=length(setup.applications), initial_objects=length(setup.topology),
        objects=length(state.nodes), days=state.step, retain=retain,
        samples=length(actual_samples), events=_event_counts(state), rng_draws=actual_draws,
        cohorts=map(cohort -> length(cohort.ids), state.cohorts),
    )
end

function _check_independent_states()
    setup = XF.authoring(; reproductive=true, rate=0.3)
    program = RP.prepare(XF.preparation_scene(setup); initial=setup.initial.templates)
    caller_models = setup.models
    caller_rng_before = XF.rng_fingerprint(caller_models)
    left = RP.instantiate(program, caller_models, native_tree(setup.topology);
        initial=setup.initial.templates, objects=setup.initial.objects, retain=true)
    right = RP.instantiate(program, caller_models, native_tree(setup.topology);
        initial=setup.initial.templates, objects=setup.initial.objects, retain=false)
    left_models = map(application -> application.model, left.applications)
    right_models = map(application -> application.model, right.applications)
    @test left.program === right.program === program
    @test left.nodes !== right.nodes
    for i in eachindex(left_models), field in _rng_fields(left_models[i])
        @test getfield(left_models[i], field) !== getfield(right_models[i], field)
        @test getfield(left_models[i], field) !== getfield(caller_models[i], field)
        @test getfield(right_models[i], field) !== getfield(caller_models[i], field)
    end
    for i in eachindex(left.cohorts), row in eachindex(left.cohorts[i].ids)
        a = left.cohorts[i].rows[row]
        b = right.cohorts[i].rows[row]
        for variable in keys(a)
            @test PSE.refvalue(a, variable) !== PSE.refvalue(b, variable)
        end
    end
    before = snapshot(right, setup.variables)
    rng_before = XF.rng_fingerprint(right_models)
    # Cross the original sex-determination threshold so independence covers
    # real RNG consumption, as well as separate owned generator identities.
    for environment in XF.rows(5)
        RP.step!(left, environment; constants=PSE.Constants())
    end
    @test XF.rng_fingerprint(left_models) != rng_before
    @test _equal(snapshot(right, setup.variables), before)
    @test XF.rng_fingerprint(right_models) == rng_before
    @test XF.rng_fingerprint(caller_models) == caller_rng_before
    @test left.step == 5
    @test right.step == 0
    return nothing
end

function run_checks(; carbon_days=3, reproductive_days=12, reproductive_rate=0.3)
    cases = NamedTuple[]
    result = @testset "Full original XPalm graph" begin
        @testset "carbon, daily growth and temporal history" begin
            push!(cases, compare_case(; days=carbon_days))
        end
        @testset "seeded reproductive case" begin
            case = compare_case(; days=reproductive_days, rate=reproductive_rate,
                reproductive=true, sex_seed=1, abortion_seed=1)
            push!(cases, case)
            # The ordinary 12-day, rate=0.3, seeds=1 reference has now been
            # observed to create both sexes. Shortened caller-selected screens
            # still compare every value, but do not claim this event coverage.
            if reproductive_days == 12 && reproductive_rate == 0.3
                @test case.events.male_objects > 0
                @test case.events.female_objects > 0
                sex_draws = only(filter(entry -> entry.application === :Phytomer__sex_determination &&
                    entry.field === :rng, case.rng_draws)).draws
                abortion_draws = only(filter(entry -> entry.application === :Phytomer__abortion &&
                    entry.field === :random_generator, case.rng_draws)).draws
                @test sex_draws isa Int && sex_draws > 0
                @test abortion_draws isa Int && abortion_draws > 0
            end
        end
        @testset "early reproductive thresholds and newborn temporal fallback" begin
            # This case is compared with the original executor; its event counts
            # remain observations until that reference has actually been run.
            push!(cases, compare_case(; days=3, rate=0.3, reproductive=true,
                flowering=6.0, abortion_duration=2.0, sex_duration=2.0,
                sex_seed=1, abortion_seed=1))
        end
        @testset "temporal history without retained outputs" begin
            push!(cases, compare_case(; days=carbon_days, retain=false))
        end
        @testset "independent state and RNG ownership" begin
            _check_independent_states()
        end
    end
    counts = Test.get_test_counts(result)
    return (passes=counts.passes + counts.cumulative_passes,
        fails=counts.fails + counts.cumulative_fails,
        errors=counts.errors + counts.cumulative_errors, cases=cases)
end

end # module FullXPalmChecks
