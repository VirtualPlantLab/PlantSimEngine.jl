"""
Finish and validate the Bonito documentation export.

Bonito 5.2 emits site-root-relative URLs even for nested Markdown pages. Give
each page an explicit site base, keep fragment links on their original page,
and adapt the theme's outline lookup. This also fixes asset URLs serialized
inside Bonito applications, which cannot be repaired by rewriting HTML alone.
"""
function finish_static_export(build_dir=joinpath(@__DIR__, "build"))
    source_dir = joinpath(@__DIR__, "src")
    pages = [
        replace(relpath(joinpath(root, file), source_dir), r"\.md$" => ".html")
        for (root, _, files) in walkdir(source_dir) for file in files
        if endswith(file, ".md")
    ]

    # Preserve Bonito's scroll-aware outline after qualifying fragment links.
    scripts = [
        joinpath(root, file)
        for (root, _, files) in walkdir(joinpath(build_dir, "bonito")) for file in files
        if occursin(r"^docs\d+\.js$", file)
    ]
    length(scripts) == 1 || error("Expected one Bonito documentation theme script")
    script = only(scripts)
    javascript = read(script, String)
    old_lookup = "a.getAttribute(\"href\").slice(1)"
    count(old_lookup, javascript) == 1 || error(
        "Bonito's outline code changed; review the nested-page export adjustment",
    )
    old_version_link = "return '<a href=\"../' + v + '/\">' + esc(v) + \"</a>\";"
    count(old_version_link, javascript) == 1 || error(
        "Bonito's version navigation changed; review the preview export adjustment",
    )
    new_version_link = "return '<a href=\"' + new URL(v + '/', window.__PSE_VERSIONS_ROOT__).href + '\">' + esc(v) + \"</a>\";"
    # Exported package assets may be read-only. Write a site-owned script and
    # leave the copied upstream asset intact.
    patched_script = joinpath(build_dir, "assets", "docs-navigation.js")
    write(patched_script, replace(javascript, old_lookup => "a.hash.slice(1)", old_version_link => new_version_link))
    original_script_url = replace(relpath(script, build_dir), '\\' => '/')

    for page in pages
        path = joinpath(build_dir, page)
        isfile(path) || error("Missing exported documentation page: $page")
        html = read(path, String)
        occursin("<base ", html) && error(
            "Bonito now emits a base URL; review the nested-page export adjustment",
        )
        base = replace(relpath(build_dir, dirname(path)), '\\' => '/') * "/"
        page_url = replace(page, '\\' => '/')
        html = replace(html, original_script_url => "assets/docs-navigation.js")
        html = replace(html, "href=\"#" => "href=\"$page_url#")

        html = normalize_local_export_links(html, path, build_dir)
        # Version metadata lives above dev/stable, and two levels above a PR preview.
        version_loader = raw"""<script>
        window.__PSE_VERSIONS_ROOT__ = new URL(
            /\/previews\/PR\d+\/$/.test(new URL(document.baseURI).pathname) ? '../../' : '../',
            document.baseURI
        ).href;
        if (new URL(document.baseURI).pathname !== '/') {
            document.write('<script src="' + window.__PSE_VERSIONS_ROOT__ + 'versions.js"><\/script>');
        }
        </script>"""
        versions_tag = r"<script\b[^>]*\bsrc=\"\.\./versions\.js\"[^>]*></script>"
        count(versions_tag, html) == 1 || error("Expected Bonito version metadata script in $page")
        html = replace(html, versions_tag => version_loader)
        extras = "<base href=\"$base\">" *
                 "<link rel=\"icon\" type=\"image/png\" href=\"assets/logo.png\">"
        count("<head>", html) == 1 || error("Expected one HTML head in $page")
        html = replace(html, "<head>" => "<head>" * extras; count=1)
        html = replace(html, "</body>" => "<link rel=\"stylesheet\" href=\"assets/brand.css\"></body>"; count=1)
        write(path, html)
    end
    check_static_export(build_dir; pages)
    return nothing
end

function normalize_local_export_links(html, page_path, build_dir)
    # Raw embeds and some Documenter contents links remain page-relative.
    return replace(html, r"(?:href|src)=\"[^\"]*\"" => matched -> begin
        attribute, reference = split(matched, "=\""; limit=2)
        reference = chop(reference; tail=1)
        occursin(r"^(?:[A-Za-z][A-Za-z0-9+.-]*:|/|#)", reference) && return matched
        target = first(split(first(split(reference, '#')), '?'))
        isempty(target) && return matched
        ispath(joinpath(build_dir, target)) && return matched
        resolved = normpath(joinpath(dirname(page_path), target))
        isfile(resolved) || return matched
        relative = replace(relpath(resolved, build_dir), '\\' => '/')
        suffix = reference[nextind(reference, lastindex(target)):end]
        "$attribute=\"$relative$suffix\""
    end)
end

function check_static_export(build_dir=joinpath(@__DIR__, "build"); pages)
    binary_files = Set{String}()
    for page in pages
        html = read(joinpath(build_dir, page), String)
        occursin(r"Bonito\.init_session\([^;]*,\s*false\);"s, html) ||
            error("Missing expected Bonito export bootstrap: $page")
        markup = replace(html, r"<script\b[^>]*>.*?</script>"s => matched -> first(split(matched, '>'; limit=2)) * ">")
        references = [m.captures[1] for m in eachmatch(r"(?:href|src)=\"([^\"]+)\"", markup)]
        for matched in eachmatch(r"Bonito\.fetch_binary\([\"']([^\"']+)[\"']\)", html)
            reference = matched.captures[1]
            push!(references, reference)
            push!(binary_files, reference)
        end
        for reference in references
            startswith(reference, "//") && continue
            occursin(r"^[A-Za-z][A-Za-z0-9+.-]*:", reference) && continue
            target = first(split(first(split(reference, '#')), '?'))
            isempty(target) && continue
            target = replace(target, "%20" => " ", "&amp;" => "&")
            # The base itself deliberately leads from this page to the site root.
            target == replace(relpath(build_dir, dirname(joinpath(build_dir, page))), '\\' => '/') * "/" && continue
            ispath(joinpath(build_dir, target)) || error(
                "Missing local export target $reference in $page",
            )
        end
    end
    isempty(binary_files) && error("Static export contains no Bonito session data")
    @info "Validated static documentation export" pages=length(pages) states=length(binary_files)
    return nothing
end
