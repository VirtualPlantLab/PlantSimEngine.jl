"""
    @process(process::String, doc::String=""; verbose::Bool=true)

This macro generate the abstract type and some boilerplate code for the simulation of a process, along 
with its documentation. It also prints out a short tutorial for implementing a model if `verbose=true`.

The abstract process type is then used as a supertype of all models implementations for the 
process, and is named "Abstract<ProcessName>Model", *e.g.* `AbstractGrowthModel` for
a process called growth.

The first argument to `@process` is the new process name, 
the second is any additional documentation that should be added 
to the `Abstract<ProcessName>Model` type, and the third determines whether 
the short tutorial should be printed or not.

Newcomers are encouraged to use this macro because it explains in detail what to do next with
the process. But more experienced users may want to directly define their process without 
printing the tutorial. To do so, you can just define a new abstract type and define it as a 
subtype of `AbstractModel`:

```julia
abstract type MyNewProcess <: AbstractModel end
```

# Examples

```julia
@process "dummy_process" "This is a dummy process that shall not be used"
```
"""
macro process(f, args...)

    # Parsing the arguments. We do that because macros don't support keyword arguments
    # out of the box (see https://stackoverflow.com/a/64116235):
    aargs = []
    aakws = Pair{Symbol,Any}[]
    for el in args
        if Meta.isexpr(el, :(=))
            # We have a keyword argument:
            push!(aakws, Pair(el.args...))
        else
            # We have a positional argument:
            push!(aargs, el)
        end
    end

    # The docstring for the process function is the first positional argument:
    if length(aargs) > 1
        error("Too many positional arguments to @process")
    end
    # and it is empty by default:
    doc = length(aargs) == 1 ? aargs[1] : ""

    # The only keyword argument is verbose, and it is true by default:
    if length(aakws) > 1 || (length(aakws) == 1 && aakws[1].first != :verbose)
        error("@process only accepts one keyword argument: verbose")
    end
    verbose = length(aakws) == 1 ? aakws[1].second : true

    process_field = Symbol(f)

    # We need strings for the docs: 
    process_name = string(process_field)
    process_abstract_type_name = string("Abstract", titlecase(process_name), "Model")
    process_abstract_type = Symbol(process_abstract_type_name)

    expr = quote
        # Generate the abstract struct for the process:
        @doc string("""
        `$($process_name)` process abstract model. 

        All models implemented to simulate the `$($process_name)` process must be a subtype of this type, *e.g.* 
        `struct My$($(titlecase(process_name)))Model <: $($process_abstract_type_name) end`.

        You can list all models implementing this process using `subtypes`:

        # Examples

        ```julia
        subtypes($($process_abstract_type_name))
        ```
        """, $(doc))
        abstract type $(esc(process_abstract_type)) <: AbstractModel end

        # Generate the function to get the process name from its type:
        PlantSimEngine.process_(::Type{$(esc(process_abstract_type))}) = Symbol($process_name)
    end

    # Print help when creating a process:
    dummy_type_name = string("My", titlecase(process_name), "Model")
    p = Term.RenderableText(
        Markdown.parse("""\'{underline bold red}$(process_name){/underline bold red}\' process, generated:

        * {#8abeff}run!(){/#8abeff} to compute the process in-place.      

        * {#8abeff}$(process_abstract_type){/#8abeff}, an abstract struct used as a supertype for models implementations.

        !!! tip "What's next?"
            You can now define one or several models implementations for the {underline bold red}$(process_name){/underline bold red} process
            by adding a method to {#8abeff}run!(){/#8abeff} with your own model type

        Here's an example implementation where we define a new model type called {underline bold red}$(dummy_type_name){/underline bold red},
        with a single parameter `a`:

        ```julia
            struct $(dummy_type_name) <: $(process_abstract_type)
                a::Float64
            end
        ```

        We also have to define the model inputs and outputs by adding methods to `inputs_`:

        ```julia
            PlantSimEngine.inputs_(::$(dummy_type_name)) = (X=-Inf,)
        ```

        And `outputs_` from PlantSimEngine:

        ```julia
            PlantSimEngine.outputs_(::$(dummy_type_name)) = (Y=-Inf,)
        ```

        Optionnaly, you can declare a hard-dependency on another process that is called
        inside your process implementation:

        ```julia
            PlantSimEngine.dep(::$(dummy_type_name)) = (other_process_name=AbstractOtherProcessModel,)
        ```

        And finally, we can define the model implementation by adding a method to `run!`:

        ```julia
        function PlantSimEngine.run!(
            ::$(dummy_type_name),
            models,
            status,
            meteo,
            constants,
            extra
        )
            status.Y = model.$(process_name).a * meteo.CO2 + status.X
            run!(model.other_process_name, models, status, meteo, constants, extra)
        end
        ```

        Note that {#8abeff}run!(){/#8abeff} takes six arguments: the model type (used for dispatch), the ModelList, the status, the meteorology,
        the constants and any extra values.

        Then we can use variables from the status as inputs or outputs, model parameters from the ModelList (indexing by process, here 
        using "$(process_name)" as the process name), and meteorology variables.

        Note that our example model has an hard-dependency on another process called `other_process_name` that is called using the {#8abeff}run!(){/#8abeff} function with 
        the process as the first argument: `run!(model.other_process_name, models, status, meteo, constants, extra)`.

        If your model can be run in parallel, you can also add traits to your model type so `PlantSimEngine` knows
        it can safely parallelize the computation:

        - over space (*i.e.* over objects):

        ```@example usepkg
        PlantSimEngine.ObjectDependencyTrait(::Type{<:$(dummy_type_name)}) = PlantSimEngine.IsObjectIndependent()
        ```

        - over time (*i.e.* time-steps):

        ```@example usepkg
        PlantSimEngine.TimeStepDependencyTrait(::Type{<:$(dummy_type_name)}) = PlantSimEngine.IsTimeStepIndependent()
        ```

        !!! tip "Variables and parameters usage"
            Note that {#8abeff}run!(){/#8abeff} takes six arguments: the model type (used
            for dispatch), the ModelList, the status, the meteorology, the constants and
            any extra values.
            Then we can use variables from the status as inputs or outputs, model parameters
            from the ModelList (indexing by process, here using "$(process_name)" as the
            process name), and meteorology variables.
        """
        )
    )

    isinteractive() && verbose && print(p)

    return expr
end
