using Test, Markdown

# Documenter executes the @example blocks, their numerical assertions, and
# doctests. Avoid tests that prescribe headings or repeated editorial labels.
@testset "PlantSimEngine documentation" begin
    ENV["PLANTSIMENGINE_DOCS_BUILD_ONLY"] = "true"
    @test include(joinpath(@__DIR__, "..", "make.jl")) === nothing
end

@testset "Generated Markdown keeps code and table structure" begin
    writer = Base.get_extension(Bonito, :BonitoDocumenterExt)
    markdown = Markdown.parse("```julia\nx = 1\ny = 2\n```\n\n| Variable | Value |\n| --- | --- |\n| LAI | 2 |")
    root = convert(writer.MA.Node, markdown)
    context = writer.DCtx(nothing, nothing, nothing, joinpath(@__DIR__, "..", "build"))
    rendered = writer.domify(context, root)
    html = repr(MIME"text/html"(), Bonito.DOM.div(rendered...))
    @test occursin("<pre><code", html)
    @test occursin("1\ny", html)
    @test occursin("<table", html)
end
