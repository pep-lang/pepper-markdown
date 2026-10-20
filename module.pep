## Markdown: CommonMark 0.31.2 and the GitHub Flavored Markdown extensions
## (tables, task lists, strikethrough, extended autolinks), parsed into a
## tree of `Node`s and rendered as HTML.
##
## Bring it in with `import markdown`. It is pure Pepper. Any text is
## Markdown, so nothing here fails; text is always escaped in the HTML, and
## `Options(safe = true)` also drops raw HTML and `javascript:` links, for
## Markdown from writers you do not trust.
##
## - `to_html`: Markdown to HTML in one step
## - `parse`, `Node`, `NodeKind`, `Alignment`: the tree, for other
##   renderers or for reading a document's structure
## - `Node.events`, `Event`: a walk over the tree as enter and leave events
## - `render_html`: a tree to HTML
## - `Options`: GFM on or off, and safe mode
##
## @example
##     import markdown;
##
##     main(): int {
##         var html = markdown.to_html("| a | b |\n| - | - |\n| ~~1~~ | 2 |\n");
##         assert(html.contains("<td><del>1</del></td>"), "a GFM table");
##         print(markdown.to_html("Hello, *world*!\n"));   # <p>Hello, <em>world</em>!</p>
##         return 0;
##     }

# This file only gathers the module's public API from its other files.

import "html";
import "node";
import "parse";

export Alignment;
export Event;
export Node;
export NodeKind;
export Options;
export parse;
export render_html;
export to_html;
