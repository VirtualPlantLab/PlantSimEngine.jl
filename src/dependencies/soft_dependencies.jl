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
    d_vars = Dict{Symbol,Vector{Pair{Symbol,NamedTuple}}}()
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
        key => [j.first => keys(j.second.inputs) for j in val] for (key, val) in d_vars
    )
    outputs_process = Dict{Symbol,Vector{Pair{Symbol,Tuple{Vararg{Symbol}}}}}(
        key => [j.first => keys(j.second.outputs) for j in val] for (key, val) in d_vars
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
                if soft_dep_graph[parent_soft_dep].parent !== nothing && i in soft_dep_graph[parent_soft_dep].parent
                    error(
                        "Cyclic dependency detected for process $proc:",
                        " $proc depends on $parent_soft_dep, which depends on $proc.",
                        " This is not allowed, but is possible via a hard dependency."
                    )
                end

                # preventing a cyclic dependency: if the current node has the parent node as a child:
                if i.children !== nothing && soft_dep_graph[parent_soft_dep] in i.children
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
function soft_dependencies_multiscale(soft_dep_graphs_roots::DependencyGraph{Dict{String,Any}}, mapping::Dict{String,A}, hard_dep_dict::Dict{Symbol, HardDependencyNode}) where {A<:Any}
    mapped_vars = mapped_variables(mapping, soft_dep_graphs_roots, verbose=false)
    rev_mapping = reverse_mapping(mapped_vars, all=false)

    independant_process_root = Dict{Pair{String,Symbol},SoftDependencyNode}()
    for (organ, (soft_dep_graph, ins, outs)) in soft_dep_graphs_roots.roots # e.g. organ = "Plant"; soft_dep_graph, ins, outs = soft_dep_graphs_roots.roots[organ]
        for (proc, i) in soft_dep_graph
            # proc = :leaf_surface; i = soft_dep_graph[proc]
            # Search if the process has soft dependencies:
            soft_deps = search_inputs_in_output(proc, ins, outs)

            # Remove the hard dependencies from the soft dependencies:
            soft_deps_not_hard = drop_process(soft_deps, [hd.process for hd in i.hard_dependency])
           
            hard_dependencies_from_other_scale = [hd for hd in i.hard_dependency if hd.scale != i.scale]

            # NB: if a node is already a hard dependency of the node, it cannot be a soft dependency
            
            # Check if the process has soft dependencies at other scales:
            soft_deps_multiscale = search_inputs_in_multiscale_output(proc, organ, ins, soft_dep_graphs_roots.roots, rev_mapping, hard_dependencies_from_other_scale)
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
                        # preventing a cyclic dependency
                        if parent_soft_dep == proc
                            error("Cyclic model dependency detected for process $proc from organ $organ.")
                        end

                        # preventing a cyclic dependency: if the parent also has a dependency on the current node:
                        if soft_dep_graph[parent_soft_dep].parent !== nothing && i in soft_dep_graph[parent_soft_dep].parent
                            error(
                                "Cyclic dependency detected for process $proc from organ $organ:",
                                " $proc depends on $parent_soft_dep, which depends on $proc.",
                                " This is not allowed, but is possible via a hard dependency."
                            )
                        end

                        # preventing a cyclic dependency: if the current node has the parent node as a child:
                        if i.children !== nothing && soft_dep_graph[parent_soft_dep] in i.children
                            error(
                                "Cyclic dependency detected for process $proc from organ $organ:",
                                " $proc depends on $parent_soft_dep, which depends on $proc.",
                                " This is not allowed, but is possible via a hard dependency."
                            )
                        end

                        i in soft_dep_graph[parent_soft_dep].children && error("Cyclic dependency detected for process $proc from organ $organ.")

                        # Add the current node as a child of the node on which it depends
                        push!(soft_dep_graph[parent_soft_dep].children, i)

                        # Add the node on which the current node depends as a parent
                        if i.parent === nothing
                            # If the node had no parent already, it is nothing, so we change into a vector
                            i.parent = [soft_dep_graph[parent_soft_dep]]
                        else
                            soft_dep_graph[parent_soft_dep] in i.parent && error("Cyclic dependency detected for process $proc from organ $organ.")
                            push!(i.parent, soft_dep_graph[parent_soft_dep])
                        end

                        # Add the soft dependencies (variables) of the parent to the current node
                        i.parent_vars = soft_deps
                    end
                end

                # If the node has soft dependencies at other scales, add it as child of the other scale (and add its parent too):
                if length(soft_deps_multiscale) > 0
                    for org in keys(soft_deps_multiscale)
                        for (parent_soft_dep, soft_dep_vars) in soft_deps_multiscale[org]                            
                                                      
                            # if the node has a soft dependency on a node that is a nested hard dependency, 
                            # have it point to the master node of that hard dependency instead of the internal node
                            # This check is meant in case the organ at the inspected scale is part of a hard dependency, 
                            # and therefore already absent from the roots

                            roots_at_given_scale = soft_dep_graphs_roots.roots[org][:soft_dep_graph]   
                            if !(parent_soft_dep in keys(roots_at_given_scale))                                                               
                                master_node = ()
                                for (hd_key, hd) in hard_dep_dict 
                                    if parent_soft_dep == hd_key     
                                        master_node = hd                                                                                                                                                                                       
                                        depth = 0
                                        # A cleaner way of preventing cycles or infinite loops would be more desirable
                                        while !isa(master_node, SoftDependencyNode) && depth < 50
                                            master_node.parent === nothing && error("Finalised hard dependency has no parent")
                                            master_node = master_node.parent
                                            depth += 1
                                        end                                      
                                        
                                        break
                                    end
                               end

                                master_node == () && error("Parent is not located in hard deps, nor in roots, which should be the case when initalizing soft dependencies")
                            
                                # NOTE : this may need to be propagated within internal hard dependencies' ancestors of this model... ?
                                parent_node = soft_dep_graphs_roots.roots[master_node.scale][:soft_dep_graph][master_node.process]
                            else
                                parent_node = soft_dep_graphs_roots.roots[org][:soft_dep_graph][parent_soft_dep]
                            end

                            # preventing a cyclic dependency: if the parent also has a dependency on the current node:
                            if parent_node.parent !== nothing && any([i == p for p in parent_node.parent])
                                error(
                                    "Cyclic dependency detected for process $proc:",
                                    " $proc for organ $organ depends on $parent_soft_dep from organ $org, which depends on the first one",
                                    " This is not allowed, you may need to develop a new process that does the whole computation by itself."
                                )
                            end

                            # preventing a cyclic dependency: if the current node has the parent node as a child:
                            if i.children !== nothing && parent_node in i.children
                                error(
                                    "Cyclic dependency detected for process $proc:",
                                    " $proc for organ $organ depends on $parent_soft_dep from organ $org, which depends on the first one.",
                                    " This is not allowed, you may need to develop a new process that does the whole computation by itself."
                                )
                            end

                            
                            if !(i in parent_node.children) # && error("Cyclic dependency detected for process $proc from organ $organ.")

                                # Add the current node as a child of the node on which it depends:
                                push!(parent_node.children, i)
                            end
                                # Add the node on which the current node depends as a parent
                            if i.parent === nothing
                                # If the node had no parent already, it is nothing, so we change into a vector
                                i.parent = [parent_node]
                            else
                                if !(parent_node in i.parent) # && error("Cyclic dependency detected for process $proc from organ $organ.")
                                    push!(i.parent, parent_node)
                                end
                            end

                            # Add the multiscale soft dependencies variables of the parent to the current node
                            i.parent_vars = NamedTuple(Symbol(k) => NamedTuple(v) for (k, v) in soft_deps_multiscale)                             
                        end
                    end
                end
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
    for (proc_output, pairs_vars_output) in outputs # e.g. proc_output = :carbon_biomass; pairs_vars_output = outs[proc_output]
        if process != proc_output
            vars_output = flatten_vars(pairs_vars_output)
            inputs_in_outputs = vars_in_variables(vars_input, vars_output)

            if any(inputs_in_outputs)
                ins_in_outs = [vars_input...][inputs_in_outputs]

                # Remove the variables that are computed at the previous time step (used to break a cyclic dependency):
                filter!(x -> !isa(x, MappedVar) || !isa(mapped_variable(x), PreviousTimeStep), ins_in_outs)

                # variables in the inputs of proc_input that are in the outputs of proc_output:
                length(ins_in_outs) > 0 && push!(inputs_as_output_of_process, proc_output => Tuple(ins_in_outs))
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
- `rev_mapping::Dict{Symbol, Symbol}`: a dict of mapped variable => source variable (this is the reverse mapping).

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
function search_inputs_in_multiscale_output(process, organ, inputs, soft_dep_graphs, rev_mapping, hard_dependencies_from_other_scale)
    # proc, organ, ins, soft_dep_graphs=soft_dep_graphs_roots.roots
    vars_input = flatten_vars(inputs[process])

    inputs_as_output_of_other_scale = Dict{String,Dict{Symbol,Vector{Symbol}}}()
    for (var, val) in pairs(vars_input) # e.g. var = :leaf_surfaces;val = vars_input[var]
        # The variable is a multiscale variable:
        if isa(val, MappedVar)
            var_organ = mapped_organ(val)
            var_organ == "" && continue # If the variable maps to nothing we skip it (e.g. [PreviousTimeStep(:var1)] or [:var => :new_var])
            if !isa(var_organ, AbstractVector)
                # In case the organ is given as a singleton (e.g. "Soil" instead of ["Soil"])
                var_organ = [var_organ]
            end

            @assert all(var_o != organ for var_o in var_organ) "$var in process $process is set to be multiscale, but points to its own scale ($organ). This is not allowed."
            for org in var_organ # e.g. org = "Leaf"
                # The variable is a multiscale variable:
                haskey(soft_dep_graphs, org) || error("Scale $org not found in the mapping, but mapped to the $organ scale.")
                mapped_var = mapped_variable(val)
                isa(mapped_var, PreviousTimeStep) && continue # Because we don't want to add the previous time step as a dependency

                # Avoid collecting variables at other scales if they come from a hard dependency
                # They are handled internally by the hard dep, so if a hard dependency contains that variable, don't add it
                # (This only needs to be done one level beneath the soft dependency nodes, any hard dependencies internal to another one don't expose their variables here)
               
                in_hard_dep::Bool = false
                hd_os_current_scale = filter(x -> x.scale == org, hard_dependencies_from_other_scale)               
                for hd_os in hd_os_current_scale
                    hd_os_output_vars = [first(p) for p in pairs(hd_os.outputs)]
                    in_hard_dep |= length(filter(x -> x == var, hd_os_output_vars)) > 0
                end
                !in_hard_dep && add_input_as_output!(inputs_as_output_of_other_scale, soft_dep_graphs, org, source_variable(val, org), mapped_var)
            end
        elseif isa(val, UninitializedVar) && haskey(rev_mapping, organ)
            # The variable may be a variable written by another scale:
            for (organ_source, proc_vars_dict) in rev_mapping[organ]
                if haskey(proc_vars_dict, var)
                    add_input_as_output!(inputs_as_output_of_other_scale, soft_dep_graphs, organ_source, var, proc_vars_dict[var])
                end
            end
        end
    end

    return inputs_as_output_of_other_scale
end


function add_input_as_output!(inputs_as_output_of_other_scale, soft_dep_graphs, organ_source, variable, value)
    for (proc_output, pairs_vars_output) in soft_dep_graphs[organ_source][:outputs] # e.g. proc_output = :maintenance_respiration; pairs_vars_output = soft_dep_graphs_roots.roots[organ_source][:outputs][proc_output]
        vars_output = flatten_vars(pairs_vars_output)

        # If the variable is found in the outputs of the process at the other scale:
        if variable in keys(vars_output)
            # The variable is found at another scale:
            if haskey(inputs_as_output_of_other_scale, organ_source)
                if haskey(inputs_as_output_of_other_scale[organ_source], proc_output)
                    push!(inputs_as_output_of_other_scale[organ_source][proc_output], value)
                else
                    inputs_as_output_of_other_scale[organ_source][proc_output] = [value]
                end
            else
                inputs_as_output_of_other_scale[organ_source] = Dict(proc_output => [value])
            end
        end
    end
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
        flatten_vars(val, vars_input)
    end
    format_flatten((vars_input...,))
end

function flatten_vars(val::NamedTuple, vars_input::Set)
    for (k, j) in pairs(val)
        push!(vars_input, k => j)
    end
end

function flatten_vars(val::Tuple, vars_input::Set)
    for j in val
        push!(vars_input, j)
    end
end

format_flatten(vars::Tuple{Vararg{Pair}}) = NamedTuple(vars)
format_flatten(vars) = vars