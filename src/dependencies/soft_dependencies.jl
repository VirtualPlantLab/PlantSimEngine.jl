"""
    soft_dependencies(d::DependencyTree)

Return a [`DependencyTree`](@ref) with the soft dependencies of the processes in the dependency tree `d`.
A soft dependency is a dependency that is not explicitely defined in the model, but that
can be inferred from the inputs and outputs of the processes.

# Arguments

- `d::DependencyTree`: the hard-dependency tree.

# Example

```julia
using PlantSimEngine

# Load the dummy models given as example in the package:
include(joinpath(pkgdir(PlantSimEngine), "examples/dummy.jl"))

# Create a model list:
models = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    process4=Process4Model(),
    process5=Process5Model(),
    process6=Process6Model(),
)

# Create the hard-dependency tree:
hard_dep = hard_dependencies(models.models, verbose=true)

# Get the soft dependencies tree:
soft_dep = soft_dependencies(hard_dep)
```
"""
function soft_dependencies(d::DependencyTree{Dict{Symbol,HardDependencyNode}})

    # Compute the variables of each node in the hard-dependency tree:
    d_vars = Dict()
    for (procname, node) in d.roots
        var = Pair{Symbol,NamedTuple}[]
        traverse_dependency_tree!(node, variables, var)
        push!(d_vars, procname => var)
    end

    # Note: all variables are collected at once for each hard-coupled nodes
    # because they are treated as one process afterwards (see below)

    # Get all nodes of the dependency tree (hard and soft):
    # all_nodes = Dict(traverse_dependency_tree(d, x -> x))

    # Compute the inputs and outputs of each process tree in the dependency tree
    inputs_process = Dict(key => [j.first => j.second.inputs for j in val] for (key, val) in d_vars)
    outputs_process = Dict(key => [j.first => j.second.outputs for j in val] for (key, val) in d_vars)

    soft_dep_tree = Dict(
        process_ => SoftDependencyNode(
            soft_dep_vars.value,
            process_, # process name
            AbstractTrees.children(soft_dep_vars), # hard dependencies
            nothing,
            nothing,
            SoftDependencyNode[],
            0
        )
        for (process_, soft_dep_vars) in d.roots
    )

    independant_process_root = Dict{Symbol,SoftDependencyNode}()
    for (proc, i) in soft_dep_tree
        # proc = :process3; i = soft_dep_tree[proc]
        # Search if the process has soft dependencies:
        soft_deps = search_inputs_in_output(proc, inputs_process, outputs_process)

        # Remove the hard dependencies from the soft dependencies:
        soft_deps_not_hard = drop_process(soft_deps, [hd.process for hd in i.hard_dependency])
        # NB: if a node is already a hard dependency of the node, it cannot be a soft dependency

        if length(soft_deps_not_hard) == 0 && i.process in keys(d.roots)
            # If the process has no soft dependencies, then it is independant (so it is a root)
            # Note that the process is only independent if it is also a root in the hard-dependency tree
            independant_process_root[proc] = i
        else
            # If the process has soft dependencies, then it is not independant
            # and we need to add its parent(s) to the node, and the node as a child
            for (parent_soft_dep, soft_dep_vars) in pairs(soft_deps_not_hard)
                # parent_soft_dep = :process5; soft_dep_vars = soft_deps[parent_soft_dep]

                # preventing a cyclic dependency
                if parent_soft_dep == proc
                    error("Cyclic model dependency detected for process $proc")
                end

                # preventing a cyclic dependency: if the parent also has a dependency on the current node:
                if soft_dep_tree[parent_soft_dep].parent !== nothing && any([i == p for p in soft_dep_tree[parent_soft_dep].parent])
                    error(
                        "Cyclic dependency detected for process $proc:",
                        " $proc depends on $parent_soft_dep, which depends on $proc.",
                        " This is not allowed, but is possible via a hard dependency."
                    )
                end

                # preventing a cyclic dependency: if the current node has the parent node as a child:
                if i.children !== nothing && any([soft_dep_tree[parent_soft_dep] == p for p in i.children])
                    error(
                        "Cyclic dependency detected for process $proc:",
                        " $proc depends on $parent_soft_dep, which depends on $proc.",
                        " This is not allowed, but is possible via a hard dependency."
                    )
                end

                # Add the current node as a child of the node on which it depends
                push!(soft_dep_tree[parent_soft_dep].children, i)

                # Add the node on which the current node depends as a parent
                if i.parent === nothing
                    # If the node had no parent already, it is nothing, so we change into a vector
                    i.parent = [soft_dep_tree[parent_soft_dep]]
                else
                    push!(i.parent, soft_dep_tree[parent_soft_dep])
                end

                # Add the soft dependencies (variables) of the parent to the current node
                i.parent_vars = soft_deps
            end
        end
    end

    return DependencyTree(independant_process_root, d.not_found)
end

"""
    drop_process(proc_vars, process)

Return a new `NamedTuple` with the process `process` removed from the `NamedTuple` `proc_vars`.

# Arguments

- `proc_vars::NamedTuple`: the `NamedTuple` from which we want to remove the process `process`.
- `process::Symbol`: the process we want to remove from the `NamedTuple` `proc_vars`.

# Returns

A new `NamedTuple` with the process `process` removed from the `NamedTuple` `proc_vars`.

# Example

```julia
julia> drop_process((a = 1, b = 2, c = 3), :b)
(a = 1, c = 3)

julia> drop_process((a = 1, b = 2, c = 3), (:a, :c))
(b = 2,)
```
"""
drop_process(proc_vars, process::Symbol) = Base.structdiff(proc_vars, NamedTuple{(process,)})
drop_process(proc_vars, process) = Base.structdiff(proc_vars, NamedTuple{(process...,)})

"""
    search_inputs_in_output(process, inputs, outputs)

Return a dictionary with the soft dependencies of the processes in the dependency tree `d`.
A soft dependency is a dependency that is not explicitely defined in the model, but that
can be inferred from the inputs and outputs of the processes.

# Arguments

- `process::Symbol`: the process for which we want to find the soft dependencies.
- `inputs::Dict{Symbol, Vector{Pair{Symbol}, Tuple{Symbol, Vararg{Symbol}}}}`: a dict of process => symbols of inputs per process.
- `outputs::Dict{Symbol, Tuple{Symbol, Vararg{Symbol}}}`: a dict of process => symbols of outputs per process.

# Details

The inputs (and similarly, outputs) give the inputs of each process, classified by the process it comes from. It can 
come from itself (its own inputs), or from another process that is a hard-dependency.

# Returns

A dictionary with the soft dependencies for the processes.

# Example

```julia
in_ = Dict(
    :process3 => [:process3=>(:var4, :var5), :process2=>(:var1, :var3), :process1=>(:var1, :var2)],
    :process4 => [:process4=>(:var0,)],
    :process6 => [:process6=>(:var7, :var9)],
    :process5 => [:process5=>(:var5, :var6)],
)

out_ = Dict(
    :process3 => Pair{Symbol}[:process3=>(:var4, :var6), :process2=>(:var4, :var5), :process1=>(:var3,)],
    :process4 => [:process4=>(:var1, :var2)],
    :process6 => [:process6=>(:var8,)],
    :process5 => [:process5=>(:var7,)],
)

search_inputs_in_output(:process3, in_, out_)
(process4 = (:var1, :var2),)
```
"""
function search_inputs_in_output(process, inputs, outputs)

    # get the inputs of the node:
    vars_input = flatten_vars(inputs[process])

    inputs_as_output_of_process = Dict()
    for (proc_output, pairs_vars_output) in outputs
        if process != proc_output
            vars_output = flatten_vars(pairs_vars_output)
            inputs_in_outputs = [i in vars_output for i in vars_input]

            if any(inputs_in_outputs)
                # variables in the inputs of proc_input that are in the outputs of proc_output
                push!(inputs_as_output_of_process, proc_output => Tuple(vars_input)[inputs_in_outputs])
                # Note: proc_output is the process that computes the inputs of proc_input
                # These inputs are given by `vars_input[inputs_in_outputs]`
            end
        end
    end

    return NamedTuple(inputs_as_output_of_process)
end


"""
    flatten_vars(vars)

Return a set of the variables in the `vars` dictionary.

# Arguments

- `vars::Dict{Symbol, Tuple{Symbol, Vararg{Symbol}}}`: a dict of process => symbols of inputs.

# Returns

A set of the variables in the `vars` dictionary.

# Example

```julia
julia> flatten_vars(Dict(:process1 => (:var1, :var2), :process2 => (:var3, :var4)))
Set{Symbol} with 4 elements:
  :var4
  :var3
  :var2
  :var1
```
"""
function flatten_vars(vars)
    vars_input = Set{Symbol}()
    for (key, val) in vars
        for j in val
            push!(vars_input, j)
        end
    end
    vars_input
end