module NativeCohortChecks

using Dates
using Test
using PlantSimEngine
import MultiScaleTreeGraph as MTG
import ..ReusableProgram
import ..PhytomerFixture
const PSE = PlantSimEngine
const RP = ReusableProgram
const PF = PhytomerFixture

PSE.@process "native_cohort_tick" verbose = false
struct Tick <: AbstractNative_Cohort_TickModel end
PSE.inputs_(::Tick) = NamedTuple()
PSE.outputs_(::Tick) = (ticks=0,)
PSE.variable_contracts_(::Tick) = (ticks=VariableContract(unit=:count),)
function PSE.run!(::Tick, status, environment, constants, context)
    status.ticks += 1
    return nothing
end

PSE.@process "native_cohort_initialize" verbose = false
struct Initialize <: AbstractNative_Cohort_InitializeModel
    fail::Bool
end
PSE.inputs_(::Initialize) = NamedTuple()
PSE.outputs_(::Initialize) = (initialized=0,)
function PSE.run!(model::Initialize, status, environment, constants, context)
    status.initialized += 1
    model.fail && error("intentional initializer failure")
    return nothing
end

PSE.@process "native_cohort_birth" verbose = false
struct Birth <: AbstractNative_Cohort_BirthModel
    mode::Symbol
    newborn_id::Int
end
PSE.inputs_(::Birth) = NamedTuple()
PSE.outputs_(::Birth) = (births=0, before_count=0, pending_count=0, targeted_count=0, target_alias=false)
function PSE.run!(model::Birth, status, environment, constants, context)
    status.before_count = length(PSE.call_targets(context, :manual))
    status.births > 0 && return nothing
    parent = PSE.source_node(context, ObjectId(2))
    id = model.mode === :duplicate ? 2 : model.newborn_id
    attributes = model.mode === :attributes ? (unexpected=1,) : NamedTuple()
    initial_status = model.mode === :type ? (ticks=1.0,) : NamedTuple()
    newborn = PSE.add_organ!(parent, context, :+, :Leaf, 4;
        id, index=1, attributes, initial_status)
    status.pending_count = length(PSE.call_targets(context, :manual))
    target_id = PSE.object_id(context, newborn)
    selected = PSE.run_call!(context, :manual; objects=target_id)
    status.targeted_count = length(selected)
    status.target_alias = PSE.refvalue(newborn, :ticks) === PSE.refvalue(only(selected).status, :ticks)
    PSE.run_initializer!(context, :initialize, target_id)
    model.mode === :double_initialize && PSE.run_initializer!(context, :initialize, target_id)
    status.births += 1
    return nothing
end

PSE.@process "native_cohort_contract_reader" verbose = false
struct ContractReader <: AbstractNative_Cohort_Contract_ReaderModel end
PSE.inputs_(::ContractReader) = (ticks=Required(Int),)
PSE.outputs_(::ContractReader) = NamedTuple()
PSE.variable_contracts_(::ContractReader) = (ticks=VariableContract(unit=:second),)
PSE.@process "native_cohort_distributed" verbose = false
struct DistributedProbe <: AbstractNative_Cohort_DistributedModel end
PSE.inputs_(::DistributedProbe) = NamedTuple()
PSE.outputs_(::DistributedProbe) = (distributed=Distributed(Default(0.0)),)

function _state(mode=:normal; existing=false, manual_one=false, fail_initializer=false)
    root = PF.tree()
    if existing
        plant = only(MTG.children(root))
        MTG.Node(5, plant, MTG.NodeMTG(:+, :Leaf, 1, 4), NamedTuple())
    end
    models = (Birth(mode, existing ? 6 : 5), Tick(), Initialize(fail_initializer))
    manual = manual_one ? One(scale=:Leaf, within=SelfPlant(), application=:tick) :
        Many(scale=:Leaf, within=SelfPlant(), application=:tick)
    specs = (
        ModelSpec(models[1]; name=:birth, on=Many(scale=:Plant), every=Day(1),
            calls=(manual=manual, initialize=Initializer(One(scale=:Leaf,
                within=SelfPlant(), application=:initialize)))),
        ModelSpec(models[2]; name=:tick, on=Many(scale=:Leaf), every=Day(1)),
        ModelSpec(models[3]; name=:initialize, on=Many(scale=:Leaf), every=Day(1)),
    )
    initial = PF.initial()
    program = RP.prepare(specs; initial)
    return RP.instantiate(program, models, root; initial, retain=true), root
end

function _status(state, id)
    cohort, row = state.locations[id]
    return state.cohorts[cohort].rows[row]
end

function run_checks()
    result = @testset "Cohort lifecycle focused contracts" begin
        @testset "pending membership and newborn targeting" begin
            state, root = _state()
            RP.step!(state, NamedTuple())
            parent = _status(state, 2)
            @test parent.before_count == 0
            @test parent.pending_count == 0
            @test parent.targeted_count == 1
            @test parent.target_alias
            @test _status(state, 5).ticks == 1
            # The initializer target remains scheduled before its creator. A new
            # object therefore runs only its explicit initializer on birth.
            @test _status(state, 5).initialized == 1
            RP.step!(state, NamedTuple())
            @test parent.before_count == 1
        end

        @testset "growth preserves refs and initializer One targets one newborn" begin
            state, root = _state(; existing=true)
            reference = PSE.refvalue(_status(state, 5), :ticks)
            RP.step!(state, NamedTuple())
            @test reference === PSE.refvalue(_status(state, 5), :ticks)
            @test _status(state, 2).before_count == 1
            @test _status(state, 2).pending_count == 1
            @test _status(state, 6).initialized == 1
            reference[] = 13
            @test _status(state, 5).ticks == 13
        end

        @testset "failed initialization cannot be replayed" begin
            for (mode, fail) in ((:double_initialize, false), (:normal, true))
                state, root = _state(mode; fail_initializer=fail)
                @test_throws Exception RP.step!(state, NamedTuple())
                @test _status(state, 5).initialized == 1
                @test_throws ArgumentError RP.step!(state, NamedTuple())
            end
        end

        @testset "creation validates before changing topology" begin
            for mode in (:duplicate, :attributes, :type)
                state, root = _state(mode)
                ids = sort!(collect(keys(state.nodes)))
                node_count = length(root)
                @test_throws ArgumentError RP.step!(state, NamedTuple())
                @test (sort!(collect(keys(state.nodes))), length(root)) == (ids, node_count)
            end
            # A targeted manual One may not use an ID to evade its scope's full
            # cardinality. Initializer One above deliberately has different rules.
            state, root = _state(; existing=true, manual_one=true)
            @test_throws ArgumentError RP.step!(state, NamedTuple())
            @test _status(state, 6).ticks == 0
        end

        @testset "scientific mismatch and unsupported distributed output" begin
            initial = PF.initial()
            tick = ModelSpec(Tick(); name=:tick, on=Many(scale=:Leaf), every=Day(1))
            reader = ModelSpec(ContractReader(); name=:reader, on=Many(scale=:Leaf), every=Day(1))
            @test_throws Exception RP.prepare((tick, reader); initial)
            distributed = ModelSpec(DistributedProbe(); name=:distributed,
                on=Many(scale=:Leaf), every=Day(1))
            @test_throws ArgumentError RP.prepare((distributed,); initial)
        end
    end
    counts = Test.get_test_counts(result)
    return (passes=counts.passes + counts.cumulative_passes,
        fails=counts.fails + counts.cumulative_fails,
        errors=counts.errors + counts.cumulative_errors)
end

end # module NativeCohortChecks
