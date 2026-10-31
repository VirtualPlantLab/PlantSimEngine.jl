module GrowthPlanAccess

using PlantSimEngine
const PSE = PlantSimEngine
const F = Main.DirectPlannerFixtures
const H = Main.DirectPlannerMeasurements
const Storage = Main.GrowthPlanStorage

export compare_plan_access

# The sink escapes the measured function. Clear it in finally so this diagnostic
# never retains model/plan/scientific references after the comparison finishes.
const _escaped_sink = Ref{Any}(nothing)

Base.@nospecializeinfer @noinline function _erased_property(application, field::Symbol)
    @nospecialize application
    return getproperty(application, field)
end

Base.@nospecializeinfer @noinline function _lookups!(sink::Vector{Any}, application,
    field::Symbol)
    @nospecialize application
    for index in eachindex(sink)
        sink[index] = _erased_property(application, field)
    end
    _escaped_sink[] = sink
    return nothing
end

Base.@nospecializeinfer @noinline function _measure_lookup(application, field::Symbol,
    nlookups::Int)
    @nospecialize application
    allocation_sink = Any[nothing for _ in 1:nlookups]
    timing_sink = Any[nothing for _ in 1:nlookups]
    # Each caller warms this complete measurement method with the same argument
    # types first. Sink construction is outside both measured passes.
    allocated = @allocated Base.invokelatest(_lookups!, allocation_sink, application, field)
    timed = @timed Base.invokelatest(_lookups!, timing_sink, application, field)
    expected = _erased_property(application, field)
    all(value -> value === expected, allocation_sink) || error("Property result changed within the allocation pass")
    all(value -> value === expected, timing_sink) || error("Property result changed within the timing pass")
    return (field, nlookups, allocated_bytes=allocated,
        allocated_bytes_per_lookup=allocated / nlookups, timed=H._phase(timed),
        result_type_name=string(nameof(typeof(expected))),
        result_shallow_payload_bytes=field === :id ? nothing : sizeof(expected),
        sink_shallow_payload_bytes=sizeof(timing_sink),
        retained_reachable_bytes=:not_measured,
        identity_note=:immutable_value_identity_is_not_distinct_heap_object_count)
end

Base.@nospecializeinfer @noinline function _prepare(model; heap=false)
    @nospecialize model
    heap && Base.invokelatest(Storage.enable_growth_plan_storage!, model)
    return Base.invokelatest(H.prepare_arm, model, :reference_executor; outputs=:none)
end

Base.@nospecializeinfer @noinline function _compare(kind::Symbol, nlookups::Int,
    requested_application)
    @nospecialize requested_application
    kind in (:pb, :xp) || throw(ArgumentError("Use the small PB or XP fixture"))
    1 <= nlookups <= 1000 || throw(ArgumentError("Use 1–1000 lookups; 200 is the small default"))
    config = H.construct_config(kind; steps=2, nobjects=2, outputs=:none)
    states = Dict{Symbol,Any}()
    states[:ordinary_fixture] = Base.invokelatest(F.construct_fixture, kind, config)
    states[:heap_fixture] = Base.invokelatest(F.construct_fixture, kind, config)
    states[:ordinary] = Base.invokelatest(_prepare, states[:ordinary_fixture].model)
    states[:heap] = Base.invokelatest(_prepare, states[:heap_fixture].model; heap=true)
    ordinary_apps = states[:ordinary].compiled.applications
    isempty(ordinary_apps) && error("The diagnostic fixture has no applications")
    if requested_application === nothing
        # Select outside timing, without touching kernels. The larger ordinary
        # shell embeds the larger immutable plan payload and is informative here.
        application = ordinary_apps[argmax(sizeof(app) for app in ordinary_apps)].id
    else
        application = Symbol(requested_application)
    end
    states[:ordinary_application] = states[:ordinary].compiled.applications_by_id[application]
    states[:heap_application] = states[:heap].compiled.applications_by_id[application]
    ordinary = states[:ordinary_application]
    heap = states[:heap_application]
    typeof(ordinary.spec) === typeof(heap.spec) || error("Independent fixtures have different spec types")
    fieldnames(typeof(ordinary.plan)) == fieldnames(typeof(heap.plan)) || error("Plan field layouts differ")
    getfield(heap, :plan) isa Storage.HeapApplicationPlan || error("Heap diagnostic did not construct a heap plan")
    rows = Any[]
    try
        for field in (:plan, :spec, :id), arm in (:ordinary, :heap)
            selected = states[Symbol(arm, :_application)]
            warm_sink = Any[nothing for _ in 1:nlookups]
            Base.invokelatest(_lookups!, warm_sink, selected, field)
            # Warm @allocated/@timed wrappers and post-pass diagnostics too.
            Base.invokelatest(_measure_lookup, selected, field, 1)
            measured = Base.invokelatest(_measure_lookup, selected, field, nlookups)
            push!(rows, (; arm, measured...))
        end
        return (kind, application, nlookups, rows,
            ordinary_shell_shallow_payload_bytes=sizeof(ordinary),
            heap_shell_shallow_payload_bytes=sizeof(heap),
            heap_report=Base.invokelatest(Storage.growth_plan_storage_report, states[:heap]),
            measured_work=:erased_property_getter_and_escaped_result_store_only,
            scientific_kernels_in_measured_loop=false,
            construction_preparation_and_validation_outside_measurements=true,
            shallow_size_scope=:inline_payload_excludes_headers_and_transitive_referents,
            retained_memory_claim=false,
            whole_application_performance_claim=false)
    finally
        _escaped_sink[] = nothing
    end
end

"""Small warmed boxing diagnostic; not a model-runtime benchmark.

Constructs independent ordinary-reference fixtures, prepares zero steps, then
measures 200 (by default) escaped erased lookups of each plan/spec/id property.
The scientific fixture constructor's caller TaskLocalRNG/seed effects are
restored by the existing fixture helper. Shallow payload sizes are not retained
memory and must not be multiplied into a reachable-memory saving claim.
"""
function compare_plan_access(kind::Symbol=:xp; nlookups::Int=200, application=nothing)
    return F.Helpers.preserve_task_rng() do
        Base.invokelatest(_compare, kind, nlookups, application)
    end
end

end # module
