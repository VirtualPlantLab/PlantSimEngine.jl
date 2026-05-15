using HTTP
using PlantSimEngine
using PlantSimEngine.Examples

abstract type AbstractE2EReebModel <: PlantSimEngine.AbstractModel end

PlantSimEngine.process_(::Type{AbstractE2EReebModel}) = :reeb_e2e

struct ReebE2E{T} <: AbstractE2EReebModel
    k::T
end

PlantSimEngine.inputs_(::ReebE2E) = (aPPFD=-Inf,)
PlantSimEngine.outputs_(::ReebE2E) = (LAI=-Inf,)

function PlantSimEngine.run!(model::ReebE2E, models, status, meteo, constants=nothing, extra=nothing)
    status.LAI = status.aPPFD * model.k
    return nothing
end

mapping = ModelMapping(
    ToyLAIModel(),
    Beer(0.5);
    status=(TT_cu=1.0, LAI=2.0),
)

session = edit_graph(mapping; port=0, open_browser=false, autosave=false)

atexit() do
    try
        close(session)
    catch
    end
end

println("PSE_GRAPH_EDITOR_URL=$(session.url)")
flush(stdout)

try
    while true
        sleep(1)
    end
catch err
    if err isa InterruptException
        close(session)
    else
        rethrow()
    end
end
