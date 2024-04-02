"""
    soft_dependencies(d::DependencyGraph)

Return a [`DependencyGraph`](@ref) with the soft dependencies of the processes in the dependency graph `d`.
A soft dependency is a dependency that is not explicitely defined in the model, but that
can be inferred from the inputs and outputs of the processes.

# Arguments

- `d::DependencyGraph`: the hard-dependency graph.

# Example

```julia
using PlantSimEngine

# Load the dummy models given as example in the package:
using PlantSimEngine.Examples

# Create a model list:
models = ModelList(
    process1=Process1Model(1.0),
    process2=Process2Model(),
    process3=Process3Model(),
    process4=Process4Model(),
    process5=Process5Model(),
    process6=Process6Model(),
)

# Create the hard-dependency graph:
hard_dep = hard_dependencies(models.models, verbose=true)

# Get the soft dependencies graph:
soft_dep = soft_dependencies(hard_dep)
```
"""
function soft_dependencies(d::DependencyGraph{Dict{Symbol,HardDependencyNode}}, nsteps=1)

    # Compute the variables of each node in the hard-dependency graph:
    d_vars = Dict{Symbol,Vector{Pair{Symbol,NamedTuple{(:inputs, :outputs),Tuple{Tuple{Vararg{Symbol}},Tuple{Vararg{Symbol}}}}}}}()
    for (procname, node) in d.roots
        var = Pair{Symbol,NamedTuple}[]
        traverse_dependency_graph!(node, variables, var)
        push!(d_vars, procname => var)
    end

    # Note: all variables are collected at once for each hard-coupled nodes
    # because they are treated as one process afterwards (see below)

    # Get all nodes of the dependency graph (hard and soft):
    # all_nodes = Dict(traverse_dependency_graph(d, x -> x))

    # Compute the inputs and outputs of each process graph in the dependency graph
    inputs_process = Dict{Symbol,Vector{Pair{Symbol,Tuple{Vararg{Symbol}}}}}(
        key => [j.first => j.second.inputs for j in val] for (key, val) in d_vars
    )
    outputs_process = Dict{Symbol,Vector{Pair{Symbol,Tuple{Vararg{Symbol}}}}}(
        key => [j.first => j.second.outputs for j in val] for (key, val) in d_vars
    )

    soft_dep_graph = Dict(
        process_ => SoftDependencyNode(
            soft_dep_vars.value,
            process_, # process name
            "",
            inputs_(soft_dep_vars.value),
            outputs_(soft_dep_vars.value),
            AbstractTrees.children(soft_dep_vars), # hard dependencies
            nothing,
            nothing,
            SoftDependencyNode[],
            fill(0, nsteps)
        )
        for (process_, soft_dep_vars) in d.roots
    )

    independant_process_root = Dict{Symbol,SoftDependencyNode}()
    for (proc, i) in soft_dep_graph
        # proc = :process3; i = soft_dep_graph[proc]
        # Search if the process has soft dependencies:
        soft_deps = search_inputs_in_output(proc, inputs_process, outputs_process)

        # Remove the hard dependencies from the soft dependencies:
        soft_deps_not_hard = drop_process(soft_deps, [hd.process for hd in i.hard_dependency])
        # NB: if a node is already a hard dependency of the node, it cannot be a soft dependency

        if length(soft_deps_not_hard) == 0 && i.process in keys(d.roots)
            # If the process has no soft dependencies, then it is independant (so it is a root)
            # Note that the process is only independent if it is also a root in the hard-dependency graph
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
                if soft_dep_graph[parent_soft_dep].parent !== nothing && any([i == p for p in soft_dep_graph[parent_soft_dep].parent])
                    error(
                        "Cyclic dependency detected for process $proc:",
                        " $proc depends on $parent_soft_dep, which depends on $proc.",
                        " This is not allowed, but is possible via a hard dependency."
                    )
                end

                # preventing a cyclic dependency: if the current node has the parent node as a child:
                if i.children !== nothing && any([soft_dep_graph[parent_soft_dep] == p for p in i.children])
                    error(
                        "Cyclic dependency detected for process $proc:",
                        " $proc depends on $parent_soft_dep, which depends on $proc.",
                        " This is not allowed, but is possible via a hard dependency."
                    )
                end

                # Add the current node as a child of the node on which it depends
                push!(soft_dep_graph[parent_soft_dep].children, i)

                # Add the node on which the current node depends as a parent
                if i.parent === nothing
                    # If the node had no parent already, it is nothing, so we change into a vector
                    i.parent = [soft_dep_graph[parent_soft_dep]]
                else
                    push!(i.parent, soft_dep_graph[parent_soft_dep])
                end

                # Add the soft dependencies (variables) of the parent to the current node
                i.parent_vars = soft_deps
            end
        end
    end

    return DependencyGraph(independant_process_root, d.not_found)
end

# For multiscale mapping:
function soft_dependencies_multiscale(soft_dep_graphs_roots::DependencyGraph{Dict{String,Any}})
    independant_process_root = Dict{Pair{String,Symbol},SoftDependencyNode}()
    for (organ, (soft_dep_graph, ins, outs)) in soft_dep_graphs_roots.roots # e.g. organ = "Leaf"; soft_dep_graph, ins, outs = soft_dep_graphs_roots.roots[organ]
        for (proc, i) in soft_dep_graph
            # proc = :carbon_demand; i = soft_dep_graph[proc]
            # Search if the process has soft dependencies:
            soft_deps = search_inputs_in_output(proc, ins, outs)

            # Remove the hard dependencies from the soft dependencies:
            soft_deps_not_hard = drop_process(soft_deps, [hd.process for hd in i.hard_dependency])
            # NB: if a node is already a hard dependency of the node, it cannot be a soft dependency

            # Check if the process has soft dependencies at other scales:
            soft_deps_multiscale = search_inputs_in_multiscale_output(proc, organ, ins, soft_dep_graphs_roots.roots)
            # Example output: "Soil" => Dict(:soil_water=>[:soil_water_content]), which means that the variable :soil_water_content
            # is computed by the process :soil_water at the scale "Soil".

            if length(soft_deps_not_hard) == 0 && i.process in keys(soft_dep_graph) && length(soft_deps_multiscale) == 0
                # If the process has no soft (multiscale) dependencies, then it is independant (so it is a root)
                # Note that the process is only independent if it is also a root in the hard-dependency graph
                independant_process_root[organ=>proc] = i
            else
                # If the process has soft dependencies at its scale, add it:
                if length(soft_deps_not_hard) > 0
                    # If the process has soft dependencies, then it is not independant
                    # and we need to add its parent(s) to the node, and the node as a child
                    for (parent_soft_dep, soft_dep_vars) in pairs(soft_deps_not_hard)
                        # parent_soft_dep = :carbon_assimilation; soft_dep_vars = soft_deps[parent_soft_dep]

                        # preventing a cyclic dependency
                        if parent_soft_dep == proc
                            error("Cyclic model dependency detected for process $proc from organ $organ.")
                        end

                        # preventing a cyclic dependency: if the parent also has a dependency on the current node:
                        if soft_dep_graph[parent_soft_dep].parent !== nothing && any([i == p for p in soft_dep_graph[parent_soft_dep].parent])
                            error(
                                "Cyclic dependency detected for process $proc from organ $organ:",
                                " $proc depends on $parent_soft_dep, which depends on $proc.",
                                " This is not allowed, but is possible via a hard dependency."
                            )
                        end

                        # preventing a cyclic dependency: if the current node has the parent node as a child:
                        if i.children !== nothing && any([soft_dep_graph[parent_soft_dep] == p for p in i.children])
                            error(
                                "Cyclic dependency detected for process $proc from organ $organ:",
                                " $proc depends on $parent_soft_dep, which depends on $proc.",
                                " This is not allowed, but is possible via a hard dependency."
                            )
                        end

                        # Add the current node as a child of the node on which it depends
                        push!(soft_dep_graph[parent_soft_dep].children, i)

                        # Add the node on which the current node depends as a parent
                        if i.parent === nothing
                            # If the node had no parent already, it is nothing, so we change into a vector
                            i.parent = [soft_dep_graph[parent_soft_dep]]
                        else
                            push!(i.parent, soft_dep_graph[parent_soft_dep])
                        end

                        # Add the soft dependencies (variables) of the parent to the current node
                        i.parent_vars = soft_deps
                    end
                end

                # If the node has soft dependencies at other scales, add it as child of the other scale (and add its parent too):
                if length(soft_deps_multiscale) > 0
                    for org in keys(soft_deps_multiscale)
                        # org = "Leaf"
                        for (parent_soft_dep, soft_dep_vars) in soft_deps_multiscale[org]
                            # parent_soft_dep= :maintenance_respiration; soft_dep_vars = soft_deps_multiscale[org][parent_soft_dep]
                            parent_node = soft_dep_graphs_roots.roots[org][:soft_dep_graph][parent_soft_dep]
                            # preventing a cyclic dependency: if the parent also has a dependency on the current node:
                            if parent_node.parent !== nothing && any([i == p for p in parent_node.parent])
                                error(
                                    "Cyclic dependency detected for process $proc:",
                                    " $proc for organ $organ depends on $parent_soft_dep from organ $org, which depends on the first one",
                                    " This is not allowed, you may need to develop a new process that does the whole computation by itself."
                                )
                            end

                            # preventing a cyclic dependency: if the current node has the parent node as a child:
                            if i.children !== nothing && any([parent_node == p for p in i.children])
                                error(
                                    "Cyclic dependency detected for process $proc:",
                                    " $proc for organ $organ depends on $parent_soft_dep from organ $org, which depends on the first one.",
                                    " This is not allowed, you may need to develop a new process that does the whole computation by itself."
                                )
                            end

                            # Add the current node as a child of the node on which it depends:
                            push!(parent_node.children, i)

                            # Add the node on which the current node depends as a parent
                            if i.parent === nothing
                                # If the node had no parent already, it is nothing, so we change into a vector
                                i.parent = [parent_node]
                            else
                                push!(i.parent, parent_node)
                            end

                            # Add the multiscale soft dependencies variables of the parent to the current node
                            i.parent_vars = NamedTuple(Symbol(k) => NamedTuple(v) for (k, v) in soft_deps_multiscale)
                        end
                    end
                end
                #! To do: make this code work without multiscale mapping, so we have only one code base for both cases. 
                #! Also, put some parts into functions to make the code more readable.
            end
        end
    end

    return DependencyGraph(independant_process_root, soft_dep_graphs_roots.not_found)
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

Return a dictionary with the soft dependencies of the processes in the dependency graph `d`.
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
    # proc, ins, outs
    # get the inputs of the node:
    vars_input = flatten_vars(inputs[process])

    inputs_as_output_of_process = Dict()
    for (proc_output, pairs_vars_output) in outputs # e.g. proc_output = :carbon_assimilation; pairs_vars_output = outs[proc_output]
        if process != proc_output
            vars_output = flatten_vars(pairs_vars_output)
            inputs_in_outputs = vars_in_variables(vars_input, vars_output)

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

function vars_in_variables(vars::T1, variables::T2) where {T1<:NamedTuple,T2<:NamedTuple}
    [i in keys(variables) for i in keys(vars)]
end

function vars_in_variables(vars, variables)
    [i in variables for i in vars]
end

"""
    search_inputs_in_multiscale_output(process, organ, inputs, soft_dep_graphs)

# Arguments

- `process::Symbol`: the process for which we want to find the soft dependencies at other scales.
- `organ::String`: the organ for which we want to find the soft dependencies.
- `inputs::Dict{Symbol, Vector{Pair{Symbol}, Tuple{Symbol, Vararg{Symbol}}}}`: a dict of process => [:subprocess => (:var1, :var2)].
- `soft_dep_graphs::Dict{String, ...}`: a dict of organ => (soft_dep_graph, inputs, outputs).

# Details

The inputs (and similarly, outputs) give the inputs of each process, classified by the process it comes from. It can
come from itself (its own inputs), or from another process that is a hard-dependency.

# Returns

A dictionary with the soft dependencies variables found in outputs of other scales for each process, e.g.:
    
```julia
Dict{String, Dict{Symbol, Vector{Symbol}}} with 2 entries:
    "Internode" => Dict(:carbon_demand=>[:carbon_demand])
    "Leaf"      => Dict(:carbon_assimilation=>[:carbon_assimilation], :carbon_demand=>[:carbon_demand])
```

This means that the variable `:carbon_demand` is computed by the process `:carbon_demand` at the scale "Internode", and the variable `:carbon_assimilation` 
is computed by the process `:carbon_assimilation` at the scale "Leaf". Those variables are used as inputs for the process that we just passed.
"""
function search_inputs_in_multiscale_output(process, organ, inputs, soft_dep_graphs)
    # proc, organ, ins, soft_dep_graphs_roots.roots
    vars_input = flatten_vars(inputs[process])

    inputs_as_output_of_other_scale = Dict{String,Dict{Symbol,Vector{Symbol}}}()
    for (var, val) in pairs(vars_input) # e.g. var = :Rm_organs;val = vars_input[var]
        # The variable is a multiscale variable:
        if isa(val, MappedVar)
            var_organ = mapped_organ(val)

            if !isa(var_organ, AbstractVector)
                # In case the organ is given as a singleton (e.g. "Soil" instead of ["Soil"])
                var_organ = [var_organ]
            end

            @assert all(var_o != organ for var_o in var_organ) "$var in process $process is set to be multiscale, but points to its own scale ($organ). This is not allowed."

            for org in var_organ # e.g. org = "Leaf"
                # The variable is a multiscale variable:
                for (proc_output, pairs_vars_output) in soft_dep_graphs[org][:outputs] # e.g. proc_output = :maintenance_respiration; pairs_vars_output = soft_dep_graphs_roots.roots[org][:outputs][proc_output]
                    # process == proc_output && @info "Process $process declared at two scales: $organ and $org. Are you sure this process has to be simulated at several scales?"
                    vars_output = flatten_vars(pairs_vars_output)

                    # If the variable is found in the outputs of the process at the other scale:
                    if source_variable(val, org) in keys(vars_output)
                        # NB: We use the variable name used in the source scale, not the one in the target scale (var.source_variable).
                        # The variable is found at another scale:
                        if haskey(inputs_as_output_of_other_scale, org)
                            if haskey(inputs_as_output_of_other_scale[org], proc_output)
                                push!(inputs_as_output_of_other_scale[org][proc_output], mapped_variable(val))
                            else
                                inputs_as_output_of_other_scale[org][proc_output] = [mapped_variable(val)]
                            end
                        else
                            inputs_as_output_of_other_scale[org] = Dict(proc_output => [mapped_variable(val)])
                        end
                    end
                end
            end
        end
    end

    return inputs_as_output_of_other_scale
end

"""
    flatten_vars(vars)

Return a set of the variables in the `vars` dictionary.

# Arguments

- `vars::Dict{Symbol, Tuple{Symbol, Vararg{Symbol}}}`: a dict of process => namedtuple of variables => value.

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

```julia
julia> flatten_vars([:process1 => (var1 = -Inf, var2 = -Inf), :process2 => (var3 = -Inf, var4 = -Inf)])
(var2 = -Inf, var4 = -Inf, var3 = -Inf, var1 = -Inf)
```
"""
function flatten_vars(vars)
    vars_input = Set()
    for (key, val) in vars
        for j in val
            push!(vars_input, j)
        end
    end
    vars_input
end

function flatten_vars(vars::Vector{N}) where {N<:Pair{Symbol}}
    vars_input = Set()
    for (key, val) in vars
        for (k, j) in pairs(val)
            push!(vars_input, k => j)
        end
    end
    (; vars_input...)
end
