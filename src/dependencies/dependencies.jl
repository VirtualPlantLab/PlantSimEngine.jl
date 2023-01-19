dep(::T) where {T<:AbstractModel} = NamedTuple()

"""
    dep(models::ModelList; verbose::Bool=true)

Get the model dependency tree given a ModelList. If one tree is returned, then all models are
coupled. If several trees are returned, then only the models inside each tree are coupled, and
the models in different trees are not coupled.

# Examples

```@example
using PlantSimEngine

# Including an example script that implements dummy processes and models:
include(joinpath(dirname(dirname(pathof(PlantSimEngine))), "examples", "dummy.jl"))

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
function dep(; verbose::Bool=true, vars...)

    hard_dep, dep_not_found = hard_dependencies((; vars...), verbose=verbose)
    deps = soft_dependencies(hard_dep)

    # Return the dependency tree
    return DependencyTree(deps, dep_not_found)
end

function dep(m::ModelList; verbose::Bool=true)
    dep(; verbose=verbose, m.models...)
end

