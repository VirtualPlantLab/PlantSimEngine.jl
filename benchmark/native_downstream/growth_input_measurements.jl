module GrowthInputMeasurements

using PlantSimEngine
const PSE=PlantSimEngine
const H=Main.DirectPlannerMeasurements
const F=Main.DirectPlannerFixtures
const M=Main.NativeDownstreamMeasurements
const CR=Main.CompiledRegionsExperiment
const PB=Main.NativePBDriver
const XP=Main.NativeXPDriver

export GROWTH_INPUT_ARMS, PREBOXED_ARMS, growth_input_policies, prepare_growth_input_arm,
    growth_input_coverage, register_growth_input_case!

const GROWTH_INPUT_ARMS=(:reference_executor,:partition,:heap_plan,:heap_partition,
    :bounded_preparation,:bounded_heap,:bounded_all)
const PREBOXED_ARMS=(:preboxed_plan,:bounded_preboxed,:preboxed_partition)
const OPTIONAL_ARMS=(:typed_driver,:typed_heap,:typed_heap_partition,:typed_preboxed)
_partition()=getfield(Main,:GrowthInputReuse)
_heap()=getfield(Main,:GrowthPlanStorage)

function growth_input_policies(arm::Symbol)
    arm in (GROWTH_INPUT_ARMS...,PREBOXED_ARMS...,OPTIONAL_ARMS...) ||
        throw(ArgumentError("Unknown growth-input arm: $arm"))
    bounded=arm in (:bounded_preparation,:bounded_heap,:bounded_all,:bounded_preboxed)
    typed=arm in OPTIONAL_ARMS
    preboxed=arm in (PREBOXED_ARMS...,:typed_preboxed)
    heap_plan=preboxed || arm in (:heap_plan,:heap_partition,:bounded_heap,:bounded_all,
        :typed_heap,:typed_heap_partition)
    return (partition=arm in (:partition,:heap_partition,:bounded_all,:typed_heap_partition,
            :preboxed_partition),heap_plan,
        payload=preboxed ? :preboxed : heap_plan ? :concrete : :none,bounded,
        underlying_arm=typed ? :selected_driver : bounded ? :bounded_preparation : :reference_executor)
end

"""Enable independent metadata policies inside the measured preparation phase.

Every sample retains original model kernels and ordinary canonical references.
No input binding, source membership, default value, sampled environment or RNG
state is shared between samples. Enabled policies precede logical compilation.
"""
Base.@nospecializeinfer @noinline function prepare_growth_input_arm(model,arm::Symbol;
    outputs=:none,performance=false,count_calls=false,constants=PSE.PlantMeteo.Constants())
    @nospecialize model outputs constants
    policy=growth_input_policies(arm)
    policy.partition && Base.invokelatest(_partition().enable_growth_input_reuse!,model)
    policy.heap_plan && Base.invokelatest(_heap().enable_growth_plan_storage!,model;
        payload=policy.payload)
    return Base.invokelatest(H.prepare_arm,model,policy.underlying_arm;
        outputs,performance,count_calls,constants)
end

# Explicitly named by the heap module's report contract once its source is
# frozen. Do not count model size or an allocated pool as optimized execution.
function _heap_positive_work(report,payload)
    report.enabled && report.heap_plans_constructed>0 && report.current_heap_plans>0 || return false
    report.payload_mode===payload || return false
    return payload===:preboxed ? report.preboxed_plans_constructed>0 && report.current_preboxed_plans>0 :
        report.concrete_plans_constructed>0 && report.current_concrete_heap_plans>0 &&
        iszero(report.preboxed_plans_constructed) && iszero(report.current_preboxed_plans)
end

Base.@nospecializeinfer @noinline function growth_input_coverage(simulation,arm::Symbol,kind;
    instrumented=false)
    @nospecialize simulation
    policy=growth_input_policies(arm)
    base=Base.invokelatest(H.coverage,simulation,policy.underlying_arm,kind;instrumented)
    partition=Base.invokelatest(_partition().growth_input_reuse_report,simulation)
    heap=Base.invokelatest(_heap().growth_plan_storage_report,simulation)
    if policy.partition
        partition.enabled || error("Partition policy not enabled")
        partition.partition_hits>0 && partition.validated_plan_tags>0 ||
            error("Partition arm reused no nonempty input-plan partition")
    else
        partition.enabled && error("Partition policy contaminated control")
        iszero(partition.partition_hits) || error("Partition control has reuse work")
    end
    if policy.heap_plan
        _heap_positive_work(heap,policy.payload) || error("Heap-plan payload performed no reported work")
    else
        heap.enabled && error("Heap-plan policy contaminated control")
        iszero(heap.heap_plans_constructed) && iszero(heap.current_heap_plans) ||
            error("Ordinary heap-plan control contains heap plan rows")
        iszero(heap.preboxed_plans_constructed) && iszero(heap.current_preboxed_plans) ||
            error("Preboxed plan payload contaminated ordinary control")
    end
    return merge(base,(growth_input_arm=arm,growth_input_policies=policy,
        partition,heap,nonempty_partition_reuses=partition.partition_hits,
        metadata_work_is_not_kernel_work=true,
        qualification_scope=:metadata_policy_operations_separate_from_actual_underlying_driver_entries))
end

"""Register a same-source independent/combined planner comparison, no execution.

M.screen_case supplies balanced forward/reverse order and fresh construction for
every sample. XP weather I/O occurs once at registration; the original fixture
copies it for each independently allocated model/tree/RNG. Complete cost includes
enablement, normal preparation and any selected-driver construction. Scientific
snapshots/types/history/topology and copied model RNG next draws are compared
after timing. Existing feature gates must pass before a larger warm screen.

Preboxed payload variants form a separate explicit cohort; select the desired
PREBOXED_ARMS when registering it. Existing arm names keep concrete payloads.
"""
Base.@nospecializeinfer @noinline function register_growth_input_case!(name::Symbol,kind::Symbol;
    steps::Int=kind===:xp ? 4 : 2,nobjects::Int=2,additions::Int=3,
    arms=GROWTH_INPUT_ARMS,outputs=:none,seed::Int=1,emission_speed::Real=0.2,
    replace::Bool=false)
    kind in (:pb,:xp,:generic) || throw(ArgumentError("Expected :pb, :xp or :generic"))
    steps>0 && nobjects>0 && additions>=0 || error("Invalid fixture dimensions")
    names=Tuple(Symbol(arm) for arm in arms)
    :reference_executor in names || error("Include the same-source ordinary control")
    config=merge(H.construct_config(kind;steps,nobjects,additions,seed,emission_speed,outputs),
        (growth_input_policies_by_arm=Dict(arm=>growth_input_policies(arm) for arm in names),
         mechanism=:input_partition_cross_heap_plan_storage,
         forcing_setup=:read_at_registration_copied_inside_each_fresh_sample))
    weather=kind===:xp ? CR._xpalm_fixture_weather(steps) : nothing
    return M.register_case!(name;config,replace,packages=(PSE,PB.PB,XP.XPalm),
        variants=Tuple(M.VariantSpec(arm) for arm in names),
        construct=(config,variant)->Base.invokelatest(F.construct_fixture,kind,config;weather),
        prepare=(fixture,config,variant)->Base.invokelatest(prepare_growth_input_arm,
            fixture.model,variant.name;outputs=config.outputs),
        lower=(simulation,fixture,config,variant)->nothing,
        execute! = (simulation,program,fixture,config,variant)->
            Base.invokelatest(PSE.continue!,simulation;steps=config.steps),
        fingerprint=(simulation,fixture,config)->(
            state=Base.invokelatest(F.snapshot,simulation,kind),
            scientific_rngs=Base.invokelatest(F.scientific_rngs,simulation.model)),
        coverage=(simulation,program,fixture,config,variant)->
            Base.invokelatest(growth_input_coverage,simulation,variant.name,kind),
        work=(simulation,fixture,config)->
            CR.downstream_work_report(simulation,fixture.initial_ids))
end

end # module
