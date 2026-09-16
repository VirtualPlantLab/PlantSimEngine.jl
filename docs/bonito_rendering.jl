module BonitoRendering

using Bonito, Documenter

const Writer = Base.get_extension(Bonito, :BonitoDocumenterExt)
isnothing(Writer) && error("Bonito's Documenter extension must be loaded")

# Documenter wraps @eval Markdown results in a MarkdownAST.Document node.
# Bonito 5.2 falls back to plain text for that root, dropping code blocks,
# tables and their formatting. Dispatch its children through the normal writer.
# Leave an upstream implementation in place when Bonito adds this method.
const document_method = which(
    Writer.domify, (Writer.DCtx, Writer.MA.Node, Writer.MA.Document),
)
if last(Base.unwrap_unionall(document_method.sig).parameters) === Any
    function Writer.domify(ctx::Writer.DCtx, node::Writer.MA.Node, ::Writer.MA.Document)
        return Writer.domify_children(ctx, node)
    end
end

end
