module AdaptiveSelectorBenchmarks

using Dates
using PlantSimEngine

# This driver uses only the package and standard libraries so exactly the same
# file can be included in Kaimon sessions for the base and candidate revisions.
# It is intentionally separate from the AirspeedVelocity suite: full scene
# compilation at the largest density is too costly for routine CI tuning.

PlantSimEngine.@process "adaptive_selector_benchmark_source" verbose = false
struct Source{V} <: AbstractAdaptive_Selector_Benchmark_SourceModel end
PlantSimEngine.inputs_(::Source) = NamedTuple()
PlantSimEngine.outputs_(::Source{V}) where {V} = NamedTuple{(V,)}((0.0,))
function PlantSimEngine.run!(::Source{V}, status, environment, constants, context) where {V}
    setproperty!(status, V, getproperty(status, V) + 1.0)
    return nothing
end

const SOURCE_VARIABLES = (:area, :A, :T_l, :lambdaE)
const INPUT_VARIABLES = (:areas, :assimilations, :temperatures, :evaporations)
const SOURCE_APPLICATIONS = (:leaf_area, :leaf_A, :leaf_T_l, :leaf_lambdaE)

PlantSimEngine.@process "adaptive_selector_benchmark_consumer" verbose = false
struct Consumer{N} <: AbstractAdaptive_Selector_Benchmark_ConsumerModel end
PlantSimEngine.inputs_(::Consumer{N}) where {N} =
    NamedTuple{INPUT_VARIABLES[1:N]}(ntuple(_ -> Required(Vector{Float64}), N))
PlantSimEngine.outputs_(::Consumer) = (total=0.0,)
function PlantSimEngine.run!(::Consumer{N}, status, environment, constants, context) where {N}
    total = 0.0
    for input in INPUT_VARIABLES[1:N]
        total += sum(getproperty(status, input))
    end
    status.total = total
    return nothing
end

function applications(ninputs::Int)
    1 <= ninputs <= length(INPUT_VARIABLES) ||
        throw(ArgumentError("`ninputs` must be between 1 and 4."))
    producers = ntuple(ninputs) do index
        ModelSpec(
            Source{SOURCE_VARIABLES[index]}();
            name=SOURCE_APPLICATIONS[index],
            on=Many(scale=:Leaf, kind=:leaf, species=:crop),
        )
    end
    inputs = NamedTuple{INPUT_VARIABLES[1:ninputs]}(ntuple(ninputs) do index
        Many(
            Subtree();
            scale=:Leaf,
            kind=:leaf,
            species=:crop,
            application=SOURCE_APPLICATIONS[index],
            var=SOURCE_VARIABLES[index],
        )
    end)
    consumer = ModelSpec(
        Consumer{ninputs}();
        name=:plant_total,
        on=Many(scale=:Plant),
        inputs=inputs,
    )
    return (producers..., consumer)
end

function fixture(objects, roots, expected; ninputs::Int)
    model = CompositeModel(
        objects...;
        applications=applications(ninputs),
        environment=(duration=Hour(1),),
    )
    selectors = Tuple(values(PlantSimEngine.value_inputs(last(model.applications))))
    matchers = map(selector -> PlantSimEngine._compile_selector_matcher(model, selector), selectors)
    return (; model, roots, expected, selectors, matchers, ninputs)
end

"""
    common_fixture(nplants; ninputs=4)

Create many bounded subtrees sharing global label buckets. Each plant has
exactly 196 objects: one plant, 47 branches, 47 matching leaf objects, and 101
other geometry objects. Four inputs select the same leaves but explicitly use
different producer applications and variables. These are generic compiler
fixtures, not an AgriPV geometry or scientific simulation.
"""
function common_fixture(nplants::Int; ninputs::Int=4)
    nplants > 0 || throw(ArgumentError("`nplants` must be positive."))
    objects = Object[Object(0; scale=:Scene, kind=:scene)]
    roots = ObjectId[]
    expected = Vector{ObjectId}[]
    for plant in 1:nplants
        root = 196 * (plant - 1) + 1
        push!(roots, ObjectId(root))
        push!(objects, Object(root; scale=:Plant, kind=:plant, species=:crop, parent=0))
        for branch in 1:47
            push!(objects, Object(root + branch; scale=:Branch, kind=:branch, species=:crop, parent=root))
            push!(objects, Object(root + 47 + branch; scale=:Leaf, kind=:leaf, species=:crop, parent=root + branch))
        end
        for geometry in 1:101
            push!(objects, Object(root + 94 + geometry; scale=:Geometry, kind=:geometry, species=:crop, parent=root + mod1(geometry, 47)))
        end
        push!(expected, ObjectId[ObjectId(root + 47 + leaf) for leaf in 1:47])
    end
    return fixture(objects, roots, expected; ninputs)
end

"""
    sparse_fixture(nobjects=100_000; nleaves=64, ninputs=4)

One huge shallow subtree has a rare matching label. Scanning the smallest
global bucket is preferable to traversing every descendant in this case.
"""
function sparse_fixture(nobjects::Int=100_000; nleaves::Int=64, ninputs::Int=4)
    1 <= nleaves < nobjects ||
        throw(ArgumentError("Require `1 <= nleaves < nobjects`."))
    objects = Object[
        Object(0; scale=:Scene, kind=:scene),
        Object(1; scale=:Plant, kind=:plant, species=:crop, parent=0),
    ]
    for index in 2:nobjects
        leaf = index <= nleaves + 1
        push!(objects, Object(index; scale=leaf ? :Leaf : :Geometry, kind=leaf ? :leaf : :geometry, species=:crop, parent=1))
    end
    return fixture(objects, ObjectId[ObjectId(1)], [ObjectId[ObjectId(index) for index in 2:(nleaves + 1)]]; ninputs)
end

function resolve(data, index, root)
    return PlantSimEngine._resolve_object_ids(
        data.model,
        data.selectors[index],
        data.matchers[index];
        context=root,
    )
end

"""Resolve every input's selector for every plant; return a compact checksum."""
function selector_sweep(data)
    count = 0
    for root in data.roots, index in eachindex(data.selectors)
        count += length(resolve(data, index, root))
    end
    return count
end

"""
Candidate-only query-work comparison. Each consumer receives a fresh cache,
matching the compiler's ownership/invalidation boundary. This measures query
resolution, dictionary lookups, and safe result copies, not full compilation.
"""
function cached_selector_sweep(data)
    count = 0
    for root in data.roots
        cache = Dict{Any,Vector{ObjectId}}()
        for index in eachindex(data.selectors)
            count += length(PlantSimEngine._cached_dependency_object_ids(
                cache, data.model, data.selectors[index], data.matchers[index], root,
            ))
        end
    end
    return count
end

"""Candidate-only gate for ordered IDs and independently owned cache results."""
function check_cached_selectors(data)
    for (root, expected) in zip(data.roots, data.expected)
        cache = Dict{Any,Vector{ObjectId}}()
        for index in eachindex(data.selectors)
            ids = PlantSimEngine._cached_dependency_object_ids(
                cache, data.model, data.selectors[index], data.matchers[index], root,
            )
            @assert ids == expected
            @assert length(cache) == 1
            @assert ids !== only(values(cache))
            ids[1] = ObjectId(-1)
            restored = PlantSimEngine._cached_dependency_object_ids(
                cache, data.model, data.selectors[index], data.matchers[index], root,
            )
            @assert restored == expected
            @assert restored !== ids && restored !== only(values(cache))
        end
    end
    return (; nplants=length(data.roots), ninputs=data.ninputs, safely_owned_results=true)
end

"""Check the ordered IDs before measuring either revision."""
function check_selectors(data)
    for (root, expected) in zip(data.roots, data.expected), index in eachindex(data.selectors)
        @assert resolve(data, index, root) == expected
    end
    return (; nplants=length(data.roots), ninputs=data.ninputs, matching_ids=sum(length, data.expected))
end

"""Check input-specific routing and live carriers outside the timed regions."""
function check_bindings(data)
    compiled = Advanced.refresh_bindings!(data.model)
    expected = Dict(root.value => [id.value for id in ids] for (root, ids) in zip(data.roots, data.expected))
    records = Diagnostics.explain_bindings(compiled)
    @assert length(records) == length(data.roots) * data.ninputs
    for record in records
        index = findfirst(==(record.input), INPUT_VARIABLES)
        @assert !isnothing(index) && index <= data.ninputs
        @assert record.application_id == :plant_total
        @assert record.source_ids == expected[record.consumer_id]
        @assert all(==(SOURCE_APPLICATIONS[index]), record.source_application_ids)
        @assert record.source_var == SOURCE_VARIABLES[index]
        @assert record.carrier_kind == :ref_vector
        @assert record.copy_semantics == :live_references
    end
    for binding in compiled.input_bindings
        source = model_status(data.model, first(binding.source_ids))
        original = getproperty(source, binding.source_var)
        try
            setproperty!(source, binding.source_var, original + 11.0)
            @assert first(Diagnostics.input_value(binding)) == original + 11.0
        finally
            setproperty!(source, binding.source_var, original)
        end
    end
    @assert Advanced.compiled_bindings(data.model) === compiled
    return length(records)
end

function median_value(values)
    ordered = sort(values)
    middle = length(ordered) ÷ 2
    return isodd(length(ordered)) ? ordered[middle + 1] : (ordered[middle] + ordered[middle + 1]) / 2
end

"""
Warm `operation` once, then measure independent GC-clean samples. Allocation
bytes are cumulative work, not retained/peak process memory. `reachable_bytes`
uses `Base.summarysize` on the final returned value; it is neither RSS nor a
peak-memory measurement and does not include code or allocator slack.
"""
function measure(operation; samples::Int=3, warmup::Bool=true, measure_reachable::Bool=true)
    samples > 0 || throw(ArgumentError("`samples` must be positive."))
    warmup && operation()
    seconds = Float64[]
    allocated_bytes = Int[]
    result = nothing
    for sample in 1:samples
        GC.gc()
        timing = @timed operation()
        result = timing.value
        push!(seconds, timing.time)
        push!(allocated_bytes, timing.bytes)
    end
    return (
        samples=samples,
        warmup=warmup,
        median_seconds=median_value(seconds),
        minimum_seconds=minimum(seconds),
        median_allocated_bytes=median_value(allocated_bytes),
        minimum_allocated_bytes=minimum(allocated_bytes),
        reachable_bytes=measure_reachable ? Base.summarysize(result) : nothing,
    )
end

function measure_fixture(factory; samples::Int=3, timestep_steps::Int=10, warmup::Bool=true, measure_reachable::Bool=true, measure_selectors::Bool=true)
    construction = measure(factory; samples, warmup, measure_reachable)
    data = factory()
    correctness = if measure_selectors
        check_selectors(data)
    else
        (; nplants=length(data.roots), ninputs=data.ninputs, matching_ids=sum(length, data.expected))
    end
    selector = measure_selectors ? measure(() -> selector_sweep(data); samples, warmup, measure_reachable) : nothing
    # Force a full compiler run and retain its result in the model. This avoids
    # a cached no-op and also avoids a redundant full compile when starting the
    # untimed simulation before measuring ordinary timesteps.
    compilation = measure(() -> Advanced.refresh_bindings!(data.model; force=true); samples, warmup, measure_reachable)
    simulation = run!(data.model; steps=1, outputs=:none)
    binding_checks = check_bindings(data)
    previous_cache = Advanced.compiled_bindings(data.model)
    timestep = measure(() -> continue!(simulation; steps=timestep_steps); samples, warmup, measure_reachable)
    @assert Advanced.compiled_bindings(data.model) === previous_cache
    # Every leaf producer increments once per step, so this aggregate checks
    # execution after the exact routing and live-reference assertions above.
    executed_steps = 1 + (samples + Int(warmup)) * timestep_steps
    for (root, expected) in zip(data.roots, data.expected)
        total = model_status(data.model, root).total
        @assert total == data.ninputs * length(expected) * executed_steps
    end
    return (
        correctness=correctness,
        binding_checks=binding_checks,
        selector_sweep_measured=measure_selectors,
        construction=construction,
        selector=selector,
        compilation=compilation,
        timestep=(; steps_per_sample=timestep_steps, timestep...),
        model_reachable_bytes=measure_reachable ? Base.summarysize(data.model) : nothing,
        ordinary_steps_reuse_compiled_bindings=true,
    )
end

"""
    run(; densities=(64, 304, 1376), sparse_objects=100_000, samples=3)

Run through Kaimon for each compared checkout, including this same driver.
Results separate object/registry construction, the raw selector sweep, full
compiler work, and already-compiled ordinary timesteps. Comparing one versus
four inputs exposes the value of sharing object-query work without sharing
input-specific producer filtering. There are no CI wall-clock assertions.
"""
function run(; densities=(64, 304, 1376), sparse_objects::Int=100_000, samples::Int=3)
    results = Pair{String,Any}[]
    for nplants in densities, ninputs in (1, 4)
        name = "common_$(nplants)_inputs_$(ninputs)"
        @info "Adaptive selector benchmark" name
        push!(results, name => measure_fixture(() -> common_fixture(nplants; ninputs); samples, measure_reachable=nplants <= 304))
    end
    for ninputs in (1, 4)
        name = "sparse_$(sparse_objects)_inputs_$(ninputs)"
        @info "Adaptive selector benchmark" name
        push!(results, name => measure_fixture(() -> sparse_fixture(sparse_objects; ninputs); samples, measure_reachable=sparse_objects <= 60_000))
    end
    return (
        package_path=Base.pathof(PlantSimEngine),
        package_version=string(Base.pkgversion(PlantSimEngine)),
        active_project=Base.active_project(),
        julia_version=string(VERSION),
        rows=Dict(results),
    )
end

end # module
