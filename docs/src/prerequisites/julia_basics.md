# Getting started with Julia

You can run the PlantSimEngine tutorials without knowing all of Julia. Start
by copying a complete example, then change one parameter and compare the
result. This page explains a few patterns you will see along the way.

## New to programming

The [Julia getting-started guide](https://docs.julialang.org/en/v1/manual/getting-started/)
explains how to start Julia and enter commands. If you prefer a video course,
[Julia Programming for Nervous Beginners](https://www.youtube.com/playlist?list=PLP8iPy9hna6Qpx0MgGyElJ5qFlaIXYf1R)
is aimed at people with no programming experience.

## Installing packages and setting up an environment

Follow [Installing PlantSimEngine](installing_plantsimengine.md) to create a
project folder and install the tutorial packages. A project environment
records which packages and versions your simulation uses.

## Essential Julia concepts for PlantSimEngine

The first tutorials mainly use these patterns:

| Code | Meaning |
|---|---|
| `lai = 2.0` | Store a value under the name `lai` |
| `Beer(0.6)` | Create a Beer model with an extinction coefficient of 0.6 |
| `run!(model; steps=30)` | Run a function, with the named option `steps=30` |
| `(LAI=2.0, TT=12.0)` | Group named values in a **named tuple** |
| `[1.0, 2.0, 3.0]` | Create an array of three values |
| `values[1]` | Read the first array entry; Julia indexing starts at 1 |
| `state.LAI` | Read the value named `LAI` from `state` |
| `values .* 2` | Multiply every array entry by 2 |

Options such as `steps=30` are called **keyword arguments**. The semicolon
separates these named options from the other arguments. A dot before an
operator, as in `.*`, applies the operation to each array entry. Julia calls
this **broadcasting**.

A function name ending in `!`, such as `run!` or `step!`, usually means that
the function changes something it was given. Here, running a simulation
updates its objects' values.

When you start writing models, you will also meet **types** and **methods**.
A type describes a kind of value; a model type can store its parameters.
A method is a version of a function for particular types of arguments.
The [first model tutorial](../journeys/modelers/basic_model.md) introduces
these ideas with a complete equation and its parameters.

## Cheatsheets

The [Julia Data Science basics](https://juliadatascience.io/julia_basics)
cover common syntax and working with tables. There are also
[cheatsheets](https://palmstudio.github.io/Biophysics_database_palm/cheatsheets/)
and a [short introductory notebook](https://palmstudio.github.io/Biophysics_database_palm/basic_syntax/).

## Troubleshooting

Ask Julia language questions on [Julia Discourse](https://discourse.julialang.org).
For errors from PlantSimEngine, use the
[common errors guide](../troubleshooting/common_errors.md).

If you know R, Python, or MATLAB, Julia's
[comparison with other languages](https://docs.julialang.org/en/v1/manual/noteworthy-differences/)
explains differences you may encounter. You can read about more advanced
features, such as type promotion and parametric types, when a model needs them.
