module PSECompiledScenario

using PlantSimEngine

@process "compiled_rate" verbose=false
@process "compiled_total" verbose=false

struct FixedRate <: AbstractCompiled_RateModel end

struct Accumulate <: AbstractCompiled_TotalModel end

PlantSimEngine.outputs_(::FixedRate) = (increment=0.0,)
PlantSimEngine.inputs_(::Accumulate) = (increment=Required(Float64),)
PlantSimEngine.outputs_(::Accumulate) = (total=0.0,)
PlantSimEngine.environment_inputs_(::Accumulate) = (factor=1.0,)

function PlantSimEngine.run!(::FixedRate, status, environment, constants, context)
    status.increment = environment.rate
    return nothing
end

function PlantSimEngine.run!(::Accumulate, status, environment, constants, context)
    status.total += status.increment * environment.factor
    return nothing
end

function make_model()
    return CompositeModel(Object(:plant);
        applications=(
            ModelSpec(Accumulate(); name=:total, on=One(id=:plant),
                environment=Environment(backend=(coefficient=1.0,), sources=(factor=:coefficient,))),
            ModelSpec(FixedRate(); name=:rate, on=One(id=:plant),
                environment=Environment(backend=(rate=2.5,))),
        ),
    )
end

# Prepare once when JuliaC loads this application. The CLI supplies the step count.
const program = Compilation.prepare(make_model())

function (@main)(args)
    length(args) in (1, 2) || throw(ArgumentError("usage: simulation STEPS [MORE_STEPS]"))
    steps = parse(Int, args[1])
    more_steps = length(args) == 2 ? parse(Int, args[2]) : 0
    min(steps, more_steps) >= 0 || throw(ArgumentError("step counts must be nonnegative"))
    continue!(program; steps)
    more_steps > 0 && continue!(program; steps=more_steps)
    println(Core.stdout, current_step(program), ',', final_state(program).total)
    return 0
end

end
