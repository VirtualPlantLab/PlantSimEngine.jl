# Getting started with Julia

PlantSimEngine (as well as its related packages) is written in Julia. The reasons why Julia was chosen are briefly discussed here : [The choice of using Julia](@ref).

Julia is a language that is gaining traction, but it isn't the most widely used in research and data science. 

Many elements will be familiar to those with an R, Python or Matlab background, but there are some noteworthy differences, and if you are new to the language, there will be a few hurdles you might have to overcome to be comfortable using the language.

This page is here to list to the parts of Julia that are most relevant regarding usage of PlantSimEngine, and point to resources that can help you grasp those basics.

## New to programming

It is not meant as a full-fledged from-scratch Julia tutorial. If you are completely new to programming, you may wish to check some other resources first, such as ones found [here](https://docs.julialang.org/en/v1/manual/getting-started/). The video course [Julia Programming for Nervous Beginners](https://www.youtube.com/playlist?list=PLP8iPy9hna6Qpx0MgGyElJ5qFlaIXYf1R) is tailored for people with no programming experience.

## Installing packages and setting up and environment

For PlantSimEngine, you can check our documentation page on the topic: [Installing and running PlantSimEngine](@ref)

## Cheatsheets

You can also find a few cheatsheets [here](https://palmstudio.github.io/Biophysics_database_palm/cheatsheets/) as well as a [short introductory notebook](https://palmstudio.github.io/Biophysics_database_palm/basic_syntax/) along with its [install instructions](https://palmstudio.github.io/Biophysics_database_palm/installation/).

## Troubleshooting

There is a documentation page showcasing some of the common errors than can occur when using PlantSimEngine, which may be worth checking if you are encountering issues: [Troubleshooting error messages](@ref).

For more Julia learning-related difficulties, you will find quick responses on the Discourse forum: [https://discourse.julialang.org](https://discourse.julialang.org).

### Noteworthy differences with other languages: 

If you wish to compare Julia to a specific language, [the noteworthy differences section](https://docs.julialang.org/en/v1/manual/noteworthy-differences/#Noteworthy-differences-from-Python) will provide you with a quick overview of the differences.

(Array indexing starts at 1, for example)

## Essential Julia concepts for PlantSimEngine

Here's a list of the main aspects of the Julia language required (beyond package management) to understand how to use PlantSimEngine to its potential:

Standard notions and constructs:

- Standard concepts of a variable, arrays, functions, function arguments
- The typing system and custom types
- Dictionaries and NamedTuple objects are used throughout the codebase

The Julia manual goes more in-depth than lighter introductions to some of these topics, so might be more useful as a reference than a starting point. You might find other guides or courses, such as https://scls.gitbooks.io/ljthw/content/_chapters/07-ex4.html, or the first section in https://julia.quantecon.org/intro.html, chapters 0-4 and 7 of the [Learn Julia the Hard Way draft](https://scls.gitbooks.io/ljthw/content/) or the interactive [Mathigon course](https://mathigon.org/course/programming-in-julia/introduction).

Also of importance:

- [Keyword arguments](https://docs.julialang.org/en/v1/manual/functions/#Keyword-Arguments) (kwargs) are present in many API functions
- [Type promotion](https://docs.julialang.org/en/v1/manual/conversion-and-promotion/#Promotion), [splatting](https://docs.julialang.org/en/v1/base/base/#...), [broadcasting](https://docs.julialang.org/en/v1/manual/functions/#man-vectorized), and [comprehensions](https://docs.julialang.org/en/v1/manual/arrays/#man-comprehensions) are also very useful (but not compulsory to get started)

Many of these are also briefly presented in [this Julia Data Science](https://juliadatascience.io/julia_basics) guide, which also happens to focus on the DataFrames.jl package.

Understanding more about methods, parametric types and the typing system is usually worthwhile, when working with Julia packages.

TODO point to Rémi's videos ? Other videos ?
TODO extra concepts useful for developers ?

