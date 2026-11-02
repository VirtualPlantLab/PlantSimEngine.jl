module DownstreamAMAPSimFixture

using AMAPSim
using PlantSimEngine
using SHA
const PSE = PlantSimEngine

haskey(ENV, "PSE_AMAPSIM_PATH") || error("Set PSE_AMAPSIM_PATH to the independently frozen AMAPSim package before loading this fixture")
const PACKAGE_ROOT = realpath(ENV["PSE_AMAPSIM_PATH"])
realpath(pkgdir(AMAPSim)) == PACKAGE_ROOT || error("AMAPSim was not loaded from PSE_AMAPSIM_PATH")
const ROOT = realpath(get(ENV, "PSE_AMAPSIM_ADAPTER_PATH", PACKAGE_ROOT))
const ADAPTER_VARIANT = Symbol(get(ENV, "PSE_AMAPSIM_ADAPTER_VARIANT", "original"))
ADAPTER_VARIANT in (:original, :typed) || error("Unknown frozen AMAP adapter variant")
const SOURCE_ORIGIN_REVISION = "86a3215e4a8ec24cb568e238007612e43e9600b5"
const BENCHMARK_SOURCE = joinpath(ROOT, "benchmark", "native_pse_benchmark.jl")
const FIXED_SOURCE_HASHES = (
    "test/fixtures/native_originals/merisier.fpa" => "052ed21866f4ee31e3126cf26c2db99d8d0d87fd75e9a190d14c9f05bf3591ce",
    "dev/native/parameters.jl" => "fe0328f4726cc7105010b076cae92c2b4f74e5777efe9ad9547a636705cf5d35",
    "benchmark/native_pse_benchmark.jl" => "a474ac24f7c002f6d0fd84516c6e705dc520e60fe6c801e797becc2eb13c3d54",
    "dev/native/pse.jl" => "a0b97ef22b370ed3ba0b85b574ede8fcf94334a150256d687088f8a3f14ce0d3",
    "dev/native/pse_projection.jl" => "619e459d71b339043bf6f6b0dac57ae4e90a14d0ef5a64c2ec063f690e47df26",
    "dev/native/pse_growth.jl" => "10059d62fe202b77182dd406213fec674fd6fbf025f078530d97b8a25f864447",
    "dev/native/engine.jl" => "f110f4e00da327469cf900f854046e5b7835ef3032060aecb144d61b155c8049",
    "dev/native/geometry.jl" => "262e3f091c69f7a03d9272705052cfc69eafefe2c17da7e2ca6b6a58ca042d75",
    "dev/native/random.jl" => "a2e816270d47aed229127c2cb3ef37f1d2e3bf9a1f3ae0c346289fb883c14150",
    "test/fixtures/native_arena/branch46.fpa" => "7e16053d3c045a86c3fc7ce7bf5fe9441bc5c67f7c0eb5e4879abcbae0d5f9b0",
)
const TYPED_SOURCE_HASHES = (
    "dev/native/pse.jl" => "e04c2900147648a3e208f7a18b48b84a450048c55d26448e8bfa00728bf30e64",
    "dev/native/pse_projection.jl" => "96c8acefb9a3d4a20a4fb5261683a7dca8fc889cb09ddedc249cb8af0b34db7b",
    "dev/native/geometry.jl" => "ee6b6dfdf680173f4dc7f8f021362b7e7a6ce5e2341c1decb841eb40f473a90d",
    "dev/native/parameters.jl" => "72670ca822849d4cf8c737158578b63723138df703b80adde5d64f40a5e170ea",
    "dev/native/engine.jl" => "c8c757c9a444fbb62bda045020990f1a3a3fbb0d3a8556db103bd84508fbb828",
)
_digest_file(path) = bytes2hex(sha256(read(path)))
for (relative, original_expected) in FIXED_SOURCE_HASHES
    typed = findfirst(pair -> first(pair) == relative, TYPED_SOURCE_HASHES)
    expected = ADAPTER_VARIANT === :typed && !isnothing(typed) ? last(TYPED_SOURCE_HASHES[typed]) : original_expected
    path = joinpath(ROOT, relative)
    isfile(path) && _digest_file(path) == expected || error("Frozen AMAP source/input mismatch: $relative")
end

function source_image(input=joinpath(ROOT, "test", "fixtures", "native_arena", "branch46.fpa"))
    paths = String[]
    for component in ("src", "ext", joinpath("dev", "native"))
        directory = joinpath(ROOT, component)
        isdir(directory) || continue
        for (directory, _, files) in walkdir(directory), name in files
            endswith(name, ".jl") && push!(paths, joinpath(directory, name))
        end
    end
    for path in (BENCHMARK_SOURCE, joinpath(ROOT, "Project.toml"), joinpath(ROOT, "Manifest.toml"), input)
        isfile(path) && push!(paths, path)
    end
    return [(path=relpath(path, ROOT), sha256=_digest_file(path)) for path in sort!(unique!(paths))]
end
const LOADED_SOURCE_IMAGE = source_image()
const LOADED_PACKAGE_IMAGE = [(path=relpath(joinpath(d,f),PACKAGE_ROOT),sha256=_digest_file(joinpath(d,f)))
    for component in ("src","ext") for (d,_,files) in walkdir(joinpath(PACKAGE_ROOT,component)) for f in files if endswith(f,".jl")]

# Original definitions only: no trajectory, ordinary PSE preparation, or native
# benchmark is executed by the included module's top-level code.
include(BENCHMARK_SOURCE)
const Bench = NativePSEBenchmark
const Native = Bench.N
const Adapter = Bench.B
const PRIVATE_STATE = :_native_pse_state
const PlantId = PSE.ObjectId{Symbol}
const OrganId = PSE.ObjectId{Tuple{Symbol,Symbol,Int}}

# Identical harness work in every arm; this is not an AMAP scientific process.
PSE.@process "juliac_amap_qualification_count" verbose=false
struct QualificationCount <: AbstractJuliac_Amap_Qualification_CountModel end
PSE.inputs_(::QualificationCount) = (observed_length=PSE.Required(Real),)
PSE.outputs_(::QualificationCount) = (qualification_runs=0,)
function PSE.run!(::QualificationCount, status, environment, constants, context)
    status.qualification_runs += 1
    return nothing
end

function verify_sources(config, image=config.source_image)
    realpath(pkgdir(AMAPSim)) == PACKAGE_ROOT || error("AMAP package binding changed")
    all(entry -> _digest_file(joinpath(PACKAGE_ROOT,entry.path))==entry.sha256,LOADED_PACKAGE_IMAGE) || error("Loaded AMAP package source changed")
    source_image(config.input) == image || error("Frozen AMAP scientific source/input image changed")
    return true
end

"""Exact architecture/geometry + original projected internode-consumer case.
The initial native organ population is empty. Increment is native development
coordinate, not physical seconds or days. FPA parsing belongs to construction.
"""
function config(; nplants::Integer=1, steps::Integer=2, increment::Real=0.5,
                seed::Integer=1, outputs=:all,
                input=joinpath(ROOT, "test", "fixtures", "native_arena", "branch46.fpa"))
    nplants > 0 && steps > 0 || throw(ArgumentError("positive plants and steps required"))
    isfinite(increment) && increment > 0 || throw(ArgumentError("positive finite development increment required"))
    outputs in (:all, :none) || throw(ArgumentError("use outputs=:all or :none"))
    0 <= seed <= typemax(UInt64) - (nplants - 1) || throw(ArgumentError("seed range must fit UInt64"))
    source_image() == LOADED_SOURCE_IMAGE || error("Sources changed since definitions were loaded")
    input = realpath(input)
    image = source_image(input)
    return (nplants=Int(nplants), steps=Int(steps), increment=Float64(increment),
        seed=UInt64(seed), outputs=outputs, input=input, input_sha256=_digest_file(input),
        source_image=image, source_root=ROOT, package_root=PACKAGE_ROOT, source_variant=ADAPTER_VARIANT===:typed ? :inference_typed : :original, source_origin_revision=SOURCE_ORIGIN_REVISION,
        geometry=true, scientific_scope=:original_native_architecture_geometry_and_PSE_internode_projection,
        consumer_scope=:original_LengthProbe_plus_identical_harness_counter,
        construction_includes_FPA_parsing=true)
end

function construct(config)
    verify_sources(config)
    parameters = AMAPSim.read_parameters(config.input)
    plant_ids = config.nplants == 1 ? (:plant,) :
        Tuple(Symbol("plant_", i) for i in 1:config.nplants)
    declarations = Tuple(Adapter.NativePlant(id, parameters;
        seed=config.seed + UInt64(i - 1), development_increment=config.increment)
        for (i, id) in enumerate(plant_ids))
    supplied = (
        PSE.ModelSpec(Bench.LengthProbe(); name=:length_probe, on=PSE.Many(scale=:IN)),
        PSE.ModelSpec(QualificationCount(); name=:qualification_count, on=PSE.Many(scale=:IN),
            inputs=(observed_length=PSE.One(within=PSE.Self(), application=:length_probe, var=:observed_length),)),
    )
    model = Adapter.scenario(declarations; applications=supplied,
        scales=(Internode=:IN,), geometry=true)
    return (model=model, plant_ids=plant_ids, initial_ids=collect(PSE.object_ids(model)),
        applications=Tuple(model.applications), constants=PSE.Constants())
end
prepare_baseline(fixture, config) = PSE.run!(fixture.model; steps=0,
    outputs=config.outputs, constants=fixture.constants)

# A closed property-iteration representation accepted by the ORIGINAL official
# NativePropertyPublisher constructor. It changes neither field mappings nor
# run!, output, input, or scientific contract declarations. It is optional
# authoring data for the compiled boundary, never silently applied to baseline.
struct StaticPropertyPairs{PAIRS} end
Base.length(::StaticPropertyPairs{PAIRS}) where {PAIRS} = length(PAIRS)
Base.iterate(::StaticPropertyPairs{PAIRS}) where {PAIRS} = iterate(PAIRS)
Base.iterate(::StaticPropertyPairs{PAIRS}, state) where {PAIRS} = iterate(PAIRS, state)
Base.eltype(::Type{<:StaticPropertyPairs}) = Tuple{Symbol,Symbol}
static_publisher(model) = model
function static_publisher(model::Adapter.NativePropertyPublisher)
    pairs = Tuple((name, source) for (name, source) in model.properties)
    properties = StaticPropertyPairs{pairs}()
    candidate = Adapter.NativePropertyPublisher(model.defaults, properties, model.revision_input)
    isequal(PSE.Authoring.model_interface(model), PSE.Authoring.model_interface(candidate)) ||
        error("Static property representation changed the original scientific interface")
    Tuple((name, source) for (name, source) in candidate.properties) == pairs ||
        error("Static property representation changed a field mapping")
    return candidate
end
models(fixture; static_properties=false) = Tuple(static_properties ? static_publisher(spec.model) : spec.model
    for spec in fixture.applications)

"""Bounded capability facts for registry-backend admission, not a claim of support."""
function admission(fixture)
    states = Tuple(Adapter.native_state(fixture.model, id) for id in fixture.plant_ids)
    for state in states
        state.plant_id isa PlantId || throw(ArgumentError("this frozen case requires Symbol plant IDs"))
        state.growth_control === state.development === state.organ_growth === state.status_factory === nothing ||
            throw(ArgumentError("this case excludes coupled allocation, development, expansion and custom status factories"))
        state.geometry && !state.coupled_pending || throw(ArgumentError("native geometry must be enabled and settled"))
        state.growth_runtime[] === nothing || throw(ArgumentError("unexpected active per-organ callback"))
        for group in state.groups
            group.mapping.symbol === :Internode && group.mapping.scale === :IN || throw(ArgumentError("unexpected projection family"))
            isnothing(group.ids) && isempty(group.required) || throw(ArgumentError("unexpected filtered projection or extra required status"))
            Tuple(group.properties) == (:length => :length,) || throw(ArgumentError("unexpected native property mapping"))
        end
    end
    return (plants=length(states), applications=length(fixture.applications),
        native_state_types=map(state -> string(typeof(state)), states),
        id_families=(string(PlantId), string(OrganId)),
        publisher_properties=(:length => :length,),
        original_scientific_kernels=true,
        registry_backend_required=true,
        registry_apis=(:runtime_model, :model_object, :model_status, :register_object!,
            :reparent_object!, :update_geometry!, :remove_object!, :geometry),
        inference_typed_source_fields=ADAPTER_VARIANT===:typed ? (:plant_id, :registered, :publisher_properties, :finite_apical_plan, :geometry_callback_barrier) : (),
        untouched_inactive_abstract_field=:growth_runtime,
        original_projection_local_Any=:desired_dictionary_and_dynamic_status_schema)
end

_digest(value) = begin
    io = IOBuffer(); Bench.value_bytes!(io, value); bytes2hex(sha256(take!(io)))
end
function registry_records(model)
    rows = [(
        id=object.id.value, parent=isnothing(object.parent) ? nothing : object.parent.value,
        children=Tuple(id.value for id in object.children), name=object.name,
        kind=object.kind, scale=object.scale, species=object.species,
        geometry=PSE.geometry(object),
        fields=Tuple((name=name, type=string(typeof(getproperty(object.status, name))),
            value=getproperty(object.status, name))
            for name in sort!(collect(propertynames(object.status)); by=string) if name !== PRIVATE_STATE),
    ) for object in PSE.model_objects(model)]
    return sort!(rows; by=row -> repr(row.id))
end
function history_records(simulation)
    rows = [(key=key, samples=Tuple((step=Float64(first(sample)),
        type=string(typeof(last(sample))), value=last(sample)) for sample in stream))
        for (key, stream) in pairs(PSE.outputs(simulation))]
    return sort!(rows; by=row -> repr(row.key))
end
function fingerprint(simulation, fixture)
    native = Tuple(let state = Adapter.native_state(fixture.model, id)
        (id=id, digest=Bench.fingerprint(state.native),
         registered=_digest(state.registered), geometry=state.geometry,
         coupled_pending=state.coupled_pending,
         callback_active=state.growth_runtime[] !== nothing)
    end for id in fixture.plant_ids)
    return (step=PSE.current_step(simulation), native=native,
        registry=_digest(registry_records(fixture.model)), history=_digest(history_records(simulation)))
end
function work(simulation, fixture)
    internodes = PSE.model_objects(fixture.model; scale=:IN)
    initial = Set(fixture.initial_ids)
    newborns = sort!([object.id.value for object in internodes if !(object.id in initial)]; by=repr)
    native = Tuple(let state = Adapter.native_state(fixture.model, id).native
        (id=id, axes=count(axis -> axis.active, state.plant.axes),
         raw_organs=length(state.plant.organs),
         active_organs=count(organ -> organ.active && state.plant.axes[organ.axis].active, state.plant.organs),
         development_time=state.plant.time, rng_draws=state.plant.rng.draws,
         processed_events=state.plant.processed)
    end for id in fixture.plant_ids)
    return (plants=length(fixture.plant_ids), steps=PSE.current_step(simulation),
        objects=length(PSE.model_objects(fixture.model)), internodes=length(internodes),
        newborn_ids=newborns, surviving_object_qualification_invocations=sum(object.status.qualification_runs for object in internodes; init=0),
        native=native)
end

end # module DownstreamAMAPSimFixture
