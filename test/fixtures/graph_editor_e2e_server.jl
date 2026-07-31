using PlantSimEngine
using PlantSimEngine.Examples
using HTTP

abstract type AbstractReebE2EModel <: PlantSimEngine.AbstractModel end
PlantSimEngine.process_(::Type{AbstractReebE2EModel}) = :reeb_e2e

struct ReebE2E{T} <: AbstractReebE2EModel
    k::T
end

ReebE2E() = ReebE2E(0.5)
PlantSimEngine.inputs_(::ReebE2E) = (aPPFD=Required(Float64),)
PlantSimEngine.outputs_(::ReebE2E) = (LAI=-Inf,)

abstract type AbstractE2EConsumerModel <: PlantSimEngine.AbstractModel end
PlantSimEngine.process_(::Type{AbstractE2EConsumerModel}) = :e2e_consumer

struct E2EConsumer <: AbstractE2EConsumerModel end
PlantSimEngine.inputs_(::E2EConsumer) = (aPPFD=Required(Float64),)
PlantSimEngine.outputs_(::E2EConsumer) = (consumed=-Inf,)

session = PlantSimEngine.GraphEditor.edit_graph(; port=0, open_browser=false, autosave=false)
atexit(() -> try
    close(session)
catch
end)

println("PSE_GRAPH_EDITOR_URL=$(session.url)")
flush(stdout)
wait(Condition())
