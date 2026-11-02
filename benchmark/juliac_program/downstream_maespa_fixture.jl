module DownstreamMAESPAFixture

using Dates, Random, Serialization, SHA
using MAESPA, PlantSimEngine
const PSE = PlantSimEngine
const SOURCE_ROOT = realpath(pkgdir(MAESPA))
const EXPECTED_ROOT = realpath(ENV["PSE_MAESPA_PATH"])
SOURCE_ROOT == EXPECTED_ROOT || error("Loaded MAESPA differs from the explicitly frozen source root")

module OriginalExample
using MAESPA, PlantSimEngine
include(joinpath(pkgdir(MAESPA), "examples", "two_species.jl"))
end

"""The unchanged native two-species canopy/soil scenario, with explicit population tiling.

One copy is exactly the package-owned example. Additional copies repeat its two
trees and structural trajectory columns in adjacent equal-area plot tiles.
Species physiology, soil properties, forcing, scientific models and calls are
unchanged. Every arm constructs an independent scene through `build_model`.
"""
function configuration(; steps=2, copies=1, start_slot=13, outputs=:all, T=Float64)
    steps isa Integer && copies isa Integer && start_slot isa Integer || throw(ArgumentError("integer scenario sizes required"))
    1 <= start_slot <= 48 || throw(ArgumentError("start_slot must be in 1:48"))
    1 <= steps <= 97-start_slot || throw(ArgumentError("requested steps exceed the original 96-row forcing"))
    copies >= 1 || throw(ArgumentError("copies must be positive"))
    outputs in (:none, :all) || throw(ArgumentError("outputs must be :none or :all"))
    T in (Float32, Float64) || throw(ArgumentError("fixture admits Float32 and Float64"))
    return (steps=Int(steps), copies=Int(copies), start_slot=Int(start_slot), outputs,
        T, trees=2*Int(copies), logical_leaf_slots=16*Int(copies), base_step_seconds=1800,
        population_layout=:adjacent_equal_area_two_species_tiles,
        shading_tree_count=2*Int(copies),
        scope=:complete_public_native_canopy_soil_non_tuzet,
        target_seed=731, meteorology_seed=941)
end

function _population_config(config::MAESPA.SimulationConfig{T}, copies) where {T}
    return MAESPA.SimulationConfig{T}(
        config.start_date, config.end_date, config.steps_per_day,
        config.species_count, copy(config.species_names), copy(config.physiology_files),
        copy(config.structure_files), MAESPA.AllTargetTrees(),
        config.shading_tree_count*copies, config.target_edge_distance,
        config.diffuse_transmission_interval_days, config.stomatal_model,
        config.photosynthetic_capacity_model, config.leaf_respiration_model,
        config.wood_respiration_model, config.sun_shade_model,
        config.leaf_temperature_iterations, config.canopy_air_iterations,
        config.equivalent_canopy_layers, config.canopy_layers,
        config.points_per_layer, config.zenith_angles, config.azimuth_angles,
        config.solar_geometry, config.climate_scenario, config.open_top_chamber,
        config.simulate_understorey, config.source_day_stride)
end
_population_table(::Nothing, copies) = nothing
_population_table(table, copies) = MAESPA.TreeDimensionTable(copy(table.dates), repeat(table.values; outer=(1,copies)))
function _population_scene(scene::MAESPA.LegacyTreeScene{T}, copies) where {T}
    length(scene.trees) == 2 && getfield.(scene.trees,:id) == [1,2] || error("fixture requires the original two-tree layout")
    plot=scene.plot
    width=plot.upper_corner[1]-plot.origin[1]
    scaled_plot=MAESPA.LegacyPlotConfig{T}(
        plot.origin, (plot.origin[1]+copies*width,plot.upper_corner[2]),
        plot.slope_rad, plot.bearing_rad, plot.shade_height, plot.plot_shape,
        plot.tree_count*copies, plot.water_balance_area*copies, plot.stocking,
        plot.wind_measurement_height, plot.roughness_length,
        plot.zero_plane_displacement_height)
    trees=MAESPA.LegacyTreeRecord{T}[]
    for tile in 0:copies-1, tree in scene.trees
        id=2tile+tree.id
        push!(trees,MAESPA.LegacyTreeRecord{T}(id,id,tree.species_id,
            (tree.position[1]+tile*width,tree.position[2],tree.position[3])))
    end
    original=scene.trajectories
    trajectories=MAESPA.LegacyTreeTrajectories(
        _population_table(original.radius_x,copies),
        _population_table(original.radius_y,copies),
        _population_table(original.crown_depth,copies),
        _population_table(original.crown_base_height,copies),
        _population_table(original.leaf_area,copies),
        _population_table(original.stem_diameter,copies))
    return MAESPA.LegacyTreeScene(scaled_plot,trees,trajectories)
end

function construct(config=configuration())
    original=OriginalExample.two_species_parameters(config.T)
    input=config.copies==1 ? original : merge(original,(
        config=_population_config(original.config,config.copies),
        scene=_population_scene(original.scene,config.copies)))
    target_rng=MersenneTwister(config.target_seed)
    meteorology_rng=MersenneTwister(config.meteorology_seed)
    model=MAESPA.build_model(input.config,input.scene;
        species_set=input.species, meteorology=input.meteorology, soil=input.soil,
        mount_leaf_exchange=true, step_index=config.start_slot,
        target_rng, meteorology_rng)
    isnothing(model.binding_cache) || error("public builder unexpectedly compiled an ordinary scenario during construction")
    return (model,input,config,target_rng,meteorology_rng,
        constants=PSE.Constants(),initial_ids=collect(PSE.object_ids(model)))
end
ordinary_start(fixture)=PSE.run!(fixture.model;steps=0,outputs=fixture.config.outputs,constants=fixture.constants)
ordinary_advance!(simulation,steps=1)=PSE.continue!(simulation;steps)

canonical(value::Union{Nothing,Missing,Symbol,AbstractString})=value
canonical(value::Union{Dates.TimeType,Dates.Period})=(type=string(typeof(value)),value=repr(value))
canonical(value::Number)=(type=string(typeof(value)),value=value)
canonical(value::Type)=(type=:JuliaType,value=string(value))
canonical(value::NamedTuple)=NamedTuple{keys(value)}(map(canonical,values(value)))
canonical(value::Tuple)=map(canonical,value)
canonical(value::Pair)=(canonical(first(value)),canonical(last(value)))
canonical(value::AbstractArray)=(type=string(typeof(value)),element_type=string(eltype(value)),shape=size(value),
    values=[canonical(item) for item in vec(value)])
canonical(value::AbstractDict)=[(key=canonical(key),value=canonical(item))
    for (key,item) in sort!(collect(pairs(value));by=pair->repr(first(pair)))]
function canonical(value)
    names=fieldnames(typeof(value))
    return (type=string(typeof(value)),fields=NamedTuple{names}(
        Tuple(canonical(getfield(value,name)) for name in names)))
end

Base.@nospecializeinfer function _rngs!(rows,seen,value,path)
    Base.@nospecialize value
    value isa Union{Nothing,Missing,Number,Symbol,AbstractString,Type,Module} && return nothing
    if ismutabletype(typeof(value))
        haskey(seen,value) && return nothing
        seen[value]=nothing
    end
    if value isa Random.AbstractRNG
        io=IOBuffer(); serialize(io,copy(value))
        push!(rows,(path=path,type=string(typeof(value)),state_sha256=bytes2hex(sha256(take!(io))),
            next_uint64=rand(copy(value),UInt64,4)))
    elseif value isa AbstractArray
        isbitstype(eltype(value)) && return nothing
        for (index,item) in enumerate(value)
            _rngs!(rows,seen,item,"$path[$index]")
        end
    elseif value isa AbstractDict
        for (key,item) in sort!(collect(pairs(value));by=pair->repr(first(pair)))
            _rngs!(rows,seen,item,"$path[$(repr(key))]")
        end
    else
        for name in fieldnames(typeof(value))
            isdefined(value,name) && _rngs!(rows,seen,getfield(value,name),"$path.$name")
        end
    end
    return nothing
end
function scientific_rngs(model,fixture)
    rows=Any[]; seen=IdDict{Any,Nothing}()
    for (index,spec) in enumerate(model.applications)
        _rngs!(rows,seen,spec.model,"application[$index].$(spec.name)")
    end
    _rngs!(rows,seen,fixture.target_rng,"construction.target_rng")
    _rngs!(rows,seen,fixture.meteorology_rng,"construction.meteorology_rng")
    return rows
end

"""Actual generator identities reachable from the separately owned native seed.
This distinguishes runtime state from RNGs used to author fixed forcing/targets.
"""
function owned_seed_rngs(seed)
    rows=Any[]
    _rngs!(rows,IdDict{Any,Nothing}(),seed,"owned_seed")
    return rows
end

function mounted_run_methods(fixture)
    rows=NamedTuple[]
    for spec in fixture.model.applications
        candidates=collect(methods(PSE.run!,Tuple{typeof(spec.model),Any,Any,Any,Any}))
        length(candidates)==1 || throw(ArgumentError("mounted model has an ambiguous run! source inventory"))
        method=only(candidates)
        push!(rows,(model_type=string(typeof(spec.model)),file=string(method.file),line=method.line))
    end
    return sort!(unique(rows);by=row->(row.file,row.line,row.model_type))
end

"""Every object/status, physical stream timestamp, committed atmosphere and RNG state."""
function ordinary_snapshot(simulation,fixture)
    objects=sort!(collect(PSE.model_objects(simulation.model));by=object->repr(object.id.value))
    states=[(object_id=canonical(object.id.value),status=canonical(PSE.final_state(simulation,object.id))) for object in objects]
    topology=[(object_id=canonical(object.id.value),parent=canonical(object.parent),children=canonical(object.children),
        scale=object.scale,kind=object.kind,species=object.species,geometry=canonical(PSE.geometry(object))) for object in objects]
    history=sort!([(key=canonical(key),samples=[(time=canonical(first(sample)),value=canonical(last(sample))) for sample in stream])
        for (key,stream) in pairs(PSE.outputs(simulation))];by=row->repr(row.key))
    backend=simulation.model.environment
    backend isa MAESPA.MAESPACanopyEnvironment || error("complete fixture requires its original canopy environment")
    return (step=PSE.current_step(simulation),states,topology,history,
        committed_canopy=canonical(backend.canopy),scientific_rngs=scientific_rngs(simulation.model,fixture))
end

function work_witness(simulation)
    objects=collect(PSE.model_objects(simulation.model))
    scales=Dict{Symbol,Int}()
    crowns=NamedTuple[]
    for object in objects
        category=isnothing(object.scale) ? :none : object.scale
        scales[category]=get(scales,category,0)+1
        category===:Crown || continue
        status=PSE.final_state(simulation,object.id)
        push!(crowns,(object_id=object.id.value,
            active=count(identity,status.logical_leaf_unit_active),
            accepted=count(identity,status.non_tuzet_logical_leaf_exchange_available),
            trials=sum(status.non_tuzet_logical_leaf_temperature_trial_count),
            mask_matches=isequal(status.logical_leaf_unit_active,status.non_tuzet_logical_leaf_exchange_available),
            aggregation_available=status.crown_leaf_exchange_aggregation_available,
            controller_available=status.non_tuzet_crown_leaf_exchange_controller_available,
            assimilation=status.net_assimilation_crown_umol_co2_s,
            temperature=status.mean_leaf_temperature_crown_c))
    end
    soil=PSE.final_state(simulation,:soil)
    return (step=PSE.current_step(simulation),objects=length(objects),applications=length(simulation.model.applications),
        scales,crowns=sort!(crowns;by=row->repr(row.object_id)),
        active=sum(row.active for row in crowns;init=0),accepted=sum(row.accepted for row in crowns;init=0),
        trials=sum(row.trials for row in crowns;init=0),
        nonzero_assimilation=count(row->isfinite(row.assimilation)&&!iszero(row.assimilation),crowns),
        soil_available=soil.soil_water_balance_available,
        soil_storage=soil.soil_storage_after_m,soil_residual=soil.soil_water_mass_balance_residual_m)
end

"""Raw original declarations; this inventory never invokes an ordinary compiler."""
function interface_inventory(fixture)
    model=fixture.model
    applications=[(name=spec.name,model_type=string(typeof(spec.model)),process=PSE.process(spec),
        target=canonical(PSE.criteria(spec.applies_to)),clock=canonical(spec.timestep),
        inputs=canonical(spec.inputs),calls=canonical(spec.calls),
        output_names=keys(PSE.outputs_(spec)),environment_inputs=keys(PSE.environment_inputs_(spec)),
        environment_outputs=keys(PSE.environment_outputs_(spec)),environment=canonical(spec.environment))
        for spec in model.applications]
    return (object_ids=canonical(PSE.object_ids(model)),object_count=length(PSE.object_ids(model)),
        application_count=length(applications),applications,
        environment_type=string(typeof(model.environment)),ordinary_binding_cache_empty=isnothing(model.binding_cache))
end

"""Finite declaration/registry features required by the complete native backend."""
function native_requirements(fixture)
    model=fixture.model
    objects=collect(PSE.model_objects(model))
    selector_fields=Set{Symbol}()
    clock_types=Set{String}()
    environments=NamedTuple[]
    local_object_schemas=Set{DataType}()
    model_types=Set{DataType}()
    for object in objects
        push!(local_object_schemas,typeof(object.status))
    end
    for spec in model.applications
        push!(model_types,typeof(spec.model))
        push!(clock_types,string(typeof(spec.timestep)))
        union!(selector_fields,keys(PSE.criteria(spec.applies_to)))
        for selector in values(spec.inputs)
            union!(selector_fields,keys(PSE.criteria(selector)))
        end
        for declaration in values(spec.calls)
            selector=declaration isa PSE.Initializer ? declaration.selector : declaration
            union!(selector_fields,keys(PSE.criteria(selector)))
        end
        if !isnothing(spec.environment) || !isempty(PSE.environment_outputs_(spec))
            push!(environments,(application=spec.name,descriptor=canonical(spec.environment),
                outputs=keys(PSE.environment_outputs_(spec))))
        end
    end
    return (object_id_types=sort!(unique(string(typeof(object.id.value)) for object in objects)),
        object_schemas=length(local_object_schemas),model_types=sort!(string.(collect(model_types))),
        selector_fields=sort!(collect(selector_fields);by=string),clock_types=sort!(collect(clock_types)),
        environment_type=string(typeof(model.environment)),environment_applications=environments,
        required_context_apis=(:call_targets,:run_call!,:call_model,:bound_input,:object_ids,:output_targets,:commit_environment!),
        registry_mutation=false,scientific_call_policy=:original_trial_then_published_replay)
end

function source_snapshot()
    files=String[joinpath(SOURCE_ROOT,"Project.toml"),joinpath(SOURCE_ROOT,"examples","two_species.jl")]
    for directory in ("src","ext")
        root=joinpath(SOURCE_ROOT,directory)
        isdir(root) || continue
        for (parent,_,names) in walkdir(root),name in names
            endswith(name,".jl") && push!(files,joinpath(parent,name))
        end
    end
    sort!(unique!(files))
    any(islink,files) && error("scientific source snapshot refuses symlinked files")
    rows=[(path=relpath(path,SOURCE_ROOT),sha256=bytes2hex(sha256(read(path)))) for path in files]
    return (root=SOURCE_ROOT,loaded_path=Base.pathof(MAESPA),version=string(Base.pkgversion(MAESPA)),files=rows,
        aggregate_sha256=bytes2hex(sha256(join((row.path*"\0"*row.sha256 for row in rows),"\n"))))
end

end
