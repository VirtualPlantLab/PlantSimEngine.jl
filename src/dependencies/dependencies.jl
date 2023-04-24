dep(::T, nsteps=1) where {T<:AbstractModel} = NamedTuple()

"""
    dep(m::ModelList, nsteps=1; verbose::Bool=true)

Get the model dependency graph given a ModelList. If one graph is returned, then all models are
coupled. If several graphs are returned, then only the models inside each graph are coupled, and
the models in different graphs are not coupled.
`nsteps` is the number of steps the dependency graph will be used over. It is used to determine
the length of the `simulation_id` argument for each soft dependencies in the graph.

# Examples

```@example
using PlantSimEngine

# Including an example script that implements dummy processes and models:
include(joinpath(pkgdir(PlantSimEngine), "examples/dummy.jl"))

models = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    status=(var1=15.0, var2=0.3)
)

dep(models)

# or directly with the processes:
vars = (
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    process4=Process4Model(),
    process5=Process5Model(),
    process6=Process6Model(),
    process7=Process7Model(),
)

dep(;vars...)
```
"""
function dep(nsteps=1; verbose::Bool=true, vars...)
    hard_dep = hard_dependencies((; vars...), verbose=verbose)
    deps = soft_dependencies(hard_dep, nsteps)

    # Return the dependency graph
    return deps
end

function dep(m::ModelList, nsteps=1; verbose::Bool=true)
    dep(nsteps; verbose=verbose, m.models...)
end


function dep(m::NamedTuple, nsteps=1; verbose::Bool=true)
    dep(nsteps; verbose=verbose, m...)
end