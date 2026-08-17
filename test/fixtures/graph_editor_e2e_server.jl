using PlantSimEngine
using PlantSimEngine.Examples
using HTTP

module GraphEditorE2EModels
using PlantSimEngine

export ReebE2E, E2EConsumer, E2ETemplateSource, E2EEnvironmentBackend

abstract type AbstractReebE2EModel <: PlantSimEngine.AbstractModel end
PlantSimEngine.process_(::Type{AbstractReebE2EModel}) = :reeb_e2e

struct ReebE2E{T} <: AbstractReebE2EModel
    k::T
end

ReebE2E() = ReebE2E(0.5)
PlantSimEngine.inputs_(::ReebE2E) = (aPPFD=PlantSimEngine.Required(Float64),)
PlantSimEngine.outputs_(::ReebE2E) = (LAI=-Inf,)

abstract type AbstractE2EConsumerModel <: PlantSimEngine.AbstractModel end
PlantSimEngine.process_(::Type{AbstractE2EConsumerModel}) = :e2e_consumer

struct E2EConsumer <: AbstractE2EConsumerModel end
PlantSimEngine.inputs_(::E2EConsumer) = (aPPFD=PlantSimEngine.Required(Float64),)
PlantSimEngine.outputs_(::E2EConsumer) = (consumed=-Inf,)

abstract type AbstractE2ETemplateSourceModel <: PlantSimEngine.AbstractModel end
PlantSimEngine.process_(::Type{AbstractE2ETemplateSourceModel}) = :e2e_template_source

struct E2ETemplateSource{T} <: AbstractE2ETemplateSourceModel
    coefficient::T
end

E2ETemplateSource() = E2ETemplateSource(1.0)
PlantSimEngine.inputs_(::E2ETemplateSource) = NamedTuple()
PlantSimEngine.outputs_(model::E2ETemplateSource) = (signal=oftype(model.coefficient, -Inf),)
PlantSimEngine.environment_inputs_(::E2ETemplateSource) = (T=0.0,)

struct E2EEnvironmentBackend <: PlantSimEngine.EnvironmentAPI.AbstractEnvironmentBackend
    name::Symbol
end
PlantSimEngine.EnvironmentAPI.environment_variables(::E2EEnvironmentBackend) = (:T, :air_temperature, :Ri_PAR_f)
PlantSimEngine.EnvironmentAPI.base_step_seconds(::E2EEnvironmentBackend) = 3600.0
PlantSimEngine.EnvironmentAPI.get_nsteps(::E2EEnvironmentBackend) = 24

end

using .GraphEditorE2EModels

plant_template = CompositeModelTemplate((
    ModelSpec(E2ETemplateSource(); name=:template_source, on=Many(scale=:Plant)),
); kind=:plant, species=:test_species)
weather = E2EEnvironmentBackend(:weather)
canopy = E2EEnvironmentBackend(:canopy)

session = PlantSimEngine.GraphEditor.edit_graph(
    ;
    templates=(plant=plant_template,),
    environments=(weather=weather, canopy=canopy),
    port=0,
    open_browser=false,
    autosave=false,
)
atexit(() -> try
    close(session)
catch
end)

println("PSE_GRAPH_EDITOR_URL=$(session.url)")
flush(stdout)
wait(Condition())
