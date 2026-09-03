"""
    @process(process::String, doc::String=""; verbose::Bool=true)

This macro generates the abstract type and process identity required to simulate a
process, together with its documentation. It also prints a short tutorial for
implementing a model when `verbose=true`.

The abstract process type is then used as a supertype of all model implementations for the
process, and is named "Abstract<ProcessName>Model", *e.g.* `AbstractGrowthModel` for
a process called growth.

The first argument to `@process` is the new process name, 
the second is any additional documentation that should be added 
to the `Abstract<ProcessName>Model` type, and the third determines whether 
the short tutorial should be printed or not.

Newcomers are encouraged to use this macro because it explains what to do next.
Defining the abstract type manually also requires an explicit process identity:

```julia
abstract type AbstractMy_New_ProcessModel <: AbstractModel end
PlantSimEngine.process_(::Type{AbstractMy_New_ProcessModel}) = :my_new_process
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
    p = Term.RenderableText(
        Markdown.parse(_process_model_tutorial(process_name, process_abstract_type))
    )

    isinteractive() && verbose && print(p)

    return expr
end

function _process_model_tutorial(process_name, process_abstract_type)
    dummy_type_name = string("My", titlecase(process_name), "Model")
    return """\'{underline bold red}$(process_name){/underline bold red}\' process, generated:

        * {#8abeff}run!(){/#8abeff} to compute the process in-place.      

        * {#8abeff}$(process_abstract_type){/#8abeff}, an abstract struct used as a supertype for model implementations.

        !!! tip "What's next?"
            You can now define one or several model implementations for the {underline bold red}$(process_name){/underline bold red} process
            by adding a method to {#8abeff}run!(){/#8abeff} with your own model type

        Here is a complete model implementation with one generic parameter,
        one status input, one sampled environmental input, and one output:

        ```julia
            struct $(dummy_type_name){T} <: $(process_abstract_type)
                a::T
            end
        ```

        Declare the status and environment interface before implementing the
        scientific calculation:

        ```julia
            PlantSimEngine.inputs_(::$(dummy_type_name)) = (X=Required(Real),)
            PlantSimEngine.outputs_(model::$(dummy_type_name)) = (Y=zero(model.a),)
            PlantSimEngine.environment_inputs_(model::$(dummy_type_name)) = (
                forcing=zero(model.a),
            )
            PlantSimEngine.environment_outputs_(::$(dummy_type_name)) = NamedTuple()
        ```

        Attach scientific meaning to every value crossing the model boundary.
        The contract below is a coherent dimensionless teaching example;
        replace it with the exact meaning of your scientific variables:

        ```julia
            const TUTORIAL_CONTRACT = VariableContract(
                unit=:dimensionless,
                basis=:object,
                temporal=:step,
                aggregation=:instantaneous,
                extent=:intensive,
            )

            PlantSimEngine.variable_contracts_(::$(dummy_type_name)) = (
                X=TUTORIAL_CONTRACT,
                forcing=TUTORIAL_CONTRACT,
                Y=TUTORIAL_CONTRACT,
            )
        ```

        Finally, keep the model's scientific calculation readable from top to
        bottom in `run!`:

        ```julia
        function PlantSimEngine.run!(
            model::$(dummy_type_name),
            status,
            environment,
            constants,
            context
        )
            status.Y = model.a * environment.forcing + status.X
            return nothing
        end
        ```

        Note that {#8abeff}run!(){/#8abeff} takes five arguments: the model type
        (used for dispatch and parameter access), the status, the sampled
        environment, constants, and runtime context.

        Fixed parameters belong to `model`, timestep-varying state belongs to
        `status`, and sampled forcing belongs to `environment`. Declare hard
        dependencies separately with `dep(...)=Call(...)` only when the parent
        model must control another model's execution.

        !!! tip "Variables and parameters usage"
            The model argument owns parameters, `status` owns bound state,
            `environment` contains sampled forcing, and `context` exposes hard
            calls and lifecycle operations.
        """
end
