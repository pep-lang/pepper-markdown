## Rendering HTML: `render_html` writes a parsed tree as HTML, and
## `to_html` parses and renders in one step.

import "characters";
import "node";
import "parse";

## Converts Markdown to HTML: `render_html(parse(markdown, options),
## options)`.
##
## Text is escaped, so `<`, `&` and `"` in it never become markup. Raw
## HTML passes through as the spec says (with GFM on, the tag filter
## escapes `<script>`, `<iframe>` and the like), unless `options.safe` is
## set, which drops it and empties dangerous link URLs.
##
## @param markdown the text to convert
## @param options the extensions to use, and whether to make the HTML safe
## @returns the HTML, a line ending after each block
## @example
##     import markdown;
##
##     main(): int {
##         print(markdown.to_html("# Title\n\nSome *emphasis* and `code`.\n"));
##         # <h1>Title</h1>
##         # <p>Some <em>emphasis</em> and <code>code</code>.</p>
##         var safe = markdown.Options(safe = true);
##         assert(markdown.to_html("<b>hi</b> [x](javascript:alert(1))\n", safe) == "<p>hi <a href=\"\">x</a></p>\n", "no raw HTML");
##         return 0;
##     }
export to_html(markdown: String, options: Options = Options()): String {
    return render_html(parse(markdown, options), options);
}

## Renders a tree from `parse` (or one built by hand) as HTML, as
## commonmark.js and cmark-gfm do.
##
## @param root the node to render, usually a `Document`
## @param options `gfm` turns the tag filter on, and `safe` drops raw HTML
##   and dangerous URLs
## @returns the HTML
export render_html(root: Node, options: Options = Options()): String {
    var renderer = _HtmlRenderer(options);
    for (var event in root.events()) {
        if (event.entering) {
            renderer._enter(event.node);
        } else {
            renderer._leave(event.node);
        }
    }
    return renderer._out.to_string();
}

# Writes HTML as a walk over the tree enters and leaves its nodes, as
# commonmark.js's renderer does, so a deep tree needs no deep recursion.
struct _HtmlRenderer {
    var _options: Options;
    var _out: StringBuilder;
    # The last byte written, so a line ending is never doubled.
    var _last: u8;
    # The node being entered or left, after its ancestors.
    var _path: Array<Node>;
    # How many images the walk is inside; their text is only `alt` text.
    var _in_image: int;

    construct(options: Options) {
        _options = options;
        _out = StringBuilder();
        _last = '\n';
        _path = Array<Node>();
    }

    _write(text: String) {
        if (!text.is_empty) {
            _out.append(text);
            _last = text.byte_at(text.size - 1);
        }
    }

    _escaped(text: String) {
        _write(_escape_html(text));
    }

    # Ends the line, unless it has just ended.
    _cr() {
        if (_last != '\n') {
            _write("\n");
        }
    }

    # Whether the current node has an ancestor `generation` levels up (1
    # for its parent) of `kind`.
    _has_ancestor(generation: ulong, kind: NodeKind): bool {
        return _path.count > generation && _path[_path.count - 1 - generation].kind == kind;
    }

    _ancestor(generation: ulong): Node {
        return _path[_path.count - 1 - generation];
    }

    # Whether the current node, a paragraph, is in an item of a tight list,
    # which leaves out its `<p>`.
    _in_tight_list(): bool {
        return _has_ancestor(2, NodeKind.List) && _ancestor(2).tight;
    }

    _enter(node: Node) {
        _path.append(node);
        var kind = node.kind;
        if (_in_image > 0) {
            if (kind == NodeKind.Text || kind == NodeKind.Code || kind == NodeKind.HtmlInline) {
                _escaped(node.literal);
            } else if (kind == NodeKind.SoftBreak || kind == NodeKind.LineBreak) {
                _write(" ");
            } else if (kind == NodeKind.Image) {
                _in_image += 1;
            }
            return;
        }
        if (kind == NodeKind.BlockQuote) {
            _cr();
            _write("<blockquote>");
            _cr();
        } else if (kind == NodeKind.List) {
            _cr();
            _write(node.ordered ? (node.start != 1 ? $"<ol start=\"{node.start}\">" : "<ol>") : "<ul>");
            _cr();
        } else if (kind == NodeKind.Item) {
            _write("<li>");
        } else if (kind == NodeKind.Paragraph) {
            if (!_in_tight_list()) {
                _cr();
                _write("<p>");
            }
            if (_has_ancestor(1, NodeKind.Item) && _ancestor(1).task && _ancestor(1).children[0] === node) {
                _write(
                    _ancestor(1).checked ?
                        "<input checked=\"\" disabled=\"\" type=\"checkbox\"> " :
                        "<input disabled=\"\" type=\"checkbox\"> "
                );
            }
        } else if (kind == NodeKind.Heading) {
            _cr();
            _write($"<h{node.level}>");
        } else if (kind == NodeKind.CodeBlock) {
            _cr();
            _write("<pre><code");
            var language = node.info;
            for (var index in 0..language.size) {
                if (_is_ascii_whitespace(language.byte_at(index))) {
                    language = language.substr_bytes(0, index);
                    break;
                }
            }
            if (!language.is_empty) {
                _write($" class=\"language-{_escape_html(language)}\"");
            }
            _write(">");
            _escaped(node.literal);
            _write("</code></pre>");
            _cr();
        } else if (kind == NodeKind.HtmlBlock) {
            _cr();
            _raw(node.literal);
            _cr();
        } else if (kind == NodeKind.ThematicBreak) {
            _cr();
            _write("<hr />");
            _cr();
        } else if (kind == NodeKind.Table) {
            _cr();
            _write("<table>\n");
        } else if (kind == NodeKind.TableRow) {
            if (node.header) {
                _write("<thead>\n");
            } else if (_has_ancestor(1, NodeKind.Table)
                && _ancestor(1).children.count > 1
                && _ancestor(1).children[1] === node) {
                _write("<tbody>\n");
            }
            _write("<tr>\n");
        } else if (kind == NodeKind.TableCell) {
            var tag = _cell_tag();
            _write(
                node.alignment == Alignment.None ? $"<{tag}>" : $"<{tag} align=\"{node.alignment.name().lower()}\">"
            );
        } else if (kind == NodeKind.Text) {
            _escaped(node.literal);
        } else if (kind == NodeKind.SoftBreak) {
            _write("\n");
        } else if (kind == NodeKind.LineBreak) {
            _write("<br />\n");
        } else if (kind == NodeKind.Code) {
            _write("<code>");
            _escaped(node.literal);
            _write("</code>");
        } else if (kind == NodeKind.HtmlInline) {
            _raw(node.literal);
        } else if (kind == NodeKind.Emphasis) {
            _write("<em>");
        } else if (kind == NodeKind.Strong) {
            _write("<strong>");
        } else if (kind == NodeKind.Strikethrough) {
            _write("<del>");
        } else if (kind == NodeKind.Link) {
            _write($"<a href=\"{_escape_html(_url(node.destination))}\"");
            _title(node);
            _write(">");
        } else if (kind == NodeKind.Image) {
            _write($"<img src=\"{_escape_html(_url(node.destination))}\" alt=\"");
            _in_image = 1;
        }
    }

    _leave(node: Node) {
        _leave_node(node);
        _path.pop();
    }

    _leave_node(node: Node) {
        var kind = node.kind;
        if (_in_image > 0) {
            if (kind != NodeKind.Image) {
                return;
            }
            _in_image -= 1;
            if (_in_image > 0) {
                return;
            }
            _write("\"");
            _title(node);
            _write(" />");
        } else if (kind == NodeKind.BlockQuote) {
            _cr();
            _write("</blockquote>");
            _cr();
        } else if (kind == NodeKind.List) {
            _cr();
            _write(node.ordered ? "</ol>" : "</ul>");
            _cr();
        } else if (kind == NodeKind.Item) {
            _write("</li>");
            _cr();
        } else if (kind == NodeKind.Paragraph) {
            if (!_in_tight_list()) {
                _write("</p>");
                _cr();
            }
        } else if (kind == NodeKind.Heading) {
            _write($"</h{node.level}>");
            _cr();
        } else if (kind == NodeKind.Table) {
            if (node.children.count > 1) {
                _write("</tbody>\n");
            }
            _write("</table>\n");
        } else if (kind == NodeKind.TableRow) {
            _write("</tr>\n");
            if (node.header) {
                _write("</thead>\n");
            }
        } else if (kind == NodeKind.TableCell) {
            _write($"</{_cell_tag()}>\n");
        } else if (kind == NodeKind.Emphasis) {
            _write("</em>");
        } else if (kind == NodeKind.Strong) {
            _write("</strong>");
        } else if (kind == NodeKind.Strikethrough) {
            _write("</del>");
        } else if (kind == NodeKind.Link) {
            _write("</a>");
        }
    }

    _title(node: Node) {
        if (!node.title.is_empty) {
            _write($" title=\"{_escape_html(node.title)}\"");
        }
    }

    # `th` for a cell of the header row, else `td`.
    _cell_tag(): String {
        return _has_ancestor(1, NodeKind.TableRow) && _ancestor(1).header ? "th" : "td";
    }

    # Writes raw HTML: dropped in safe mode, and with GFM on, filtered.
    _raw(html: String) {
        if (_options.safe) {
            return;
        }
        _write(_options.gfm ? _filter_tags(html) : html);
    }

    # The URL to write for `destination`: empty in safe mode when it is
    # dangerous.
    _url(destination: String): String {
        return _options.safe && _is_dangerous_url(destination) ? "" : destination;
    }
}

# Whether `url` runs script or reads local files when followed:
# `javascript:`, `vbscript:`, `file:`, or `data:` other than a PNG, GIF,
# JPEG or WebP image.
private _is_dangerous_url(url: String): bool {
    var lower = url.lower();
    if (lower.starts_with("javascript:") || lower.starts_with("vbscript:") || lower.starts_with("file:")) {
        return true;
    }
    if (!lower.starts_with("data:")) {
        return false;
    }
    for (var image in ["png", "gif", "jpeg", "webp"]) {
        if (lower.starts_with($"data:image/{image}")) {
            return false;
        }
    }
    return true;
}

# GFM's tag filter: `html` with the `<` of each `title`, `textarea`,
# `style`, `xmp`, `iframe`, `noembed`, `noframes`, `script` and
# `plaintext` tag escaped, so it shows as text.
private _filter_tags(html: String): String {
    if (!html.contains("<")) {
        return html;
    }
    var out = StringBuilder();
    var start: ulong = 0;
    for (var index in 0..html.size) {
        if (html.byte_at(index) != '<') {
            continue;
        }
        var name_start = index + 1 < html.size && html.byte_at(index + 1) == '/' ? index + 2 : index + 1;
        var name_end = name_start;
        while (name_end < html.size && html.byte_at(name_end).is_alphabetic()) {
            name_end += 1;
        }
        var name = html.substr_bytes(name_start, name_end - name_start).lower();
        if (!" title textarea style xmp iframe noembed noframes script plaintext ".contains(" " + name + " ")
            || name.is_empty) {
            continue;
        }
        var after = name_end < html.size ? html.byte_at(name_end) as int : -1;
        if (after == -1
            || _is_ascii_whitespace(after)
            || after == '>'
            || (after == '/' && name_end + 1 < html.size && html.byte_at(name_end + 1) == '>')) {
            out.append(html.substr_bytes(start, index - start));
            out.append("&lt;");
            start = index + 1;
        }
    }
    out.append(html.substr_bytes(start, html.size - start));
    return out.to_string();
}
