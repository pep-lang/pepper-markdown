# The markdown package beyond the spec examples: safe mode, the tag filter,
# GFM on and off, the tree and its events, and inputs a spec example does
# not cover.

import markdown;
import text;

safe_html(source: String): String {
    return markdown.to_html(source, markdown.Options(safe = true));
}

[Test]
safe_mode_drops_raw_html() {
    expect_equal(safe_html("<div onclick=\"x()\">\nhi\n</div>\n"), "");
    expect_equal(safe_html("a <b>bold</b> <!-- c -->\n"), "<p>a bold </p>\n");
    expect_equal(safe_html("<script>alert(1)</script>\n"), "");
    # Text is escaped in every mode.
    expect_equal(safe_html("a < b & \"c\"\n"), "<p>a &lt; b &amp; &quot;c&quot;</p>\n");
    expect_equal(markdown.to_html("a <b>bold</b>\n"), "<p>a <b>bold</b></p>\n");
}

[Test]
safe_mode_empties_dangerous_urls() {
    expect_equal(safe_html("[x](javascript:alert(1))\n"), "<p><a href=\"\">x</a></p>\n");
    expect_equal(safe_html("[x](JaVaScRiPt:alert(1))\n"), "<p><a href=\"\">x</a></p>\n");
    expect_equal(safe_html("[x](&#106;avascript:alert(1))\n"), "<p><a href=\"\">x</a></p>\n");
    expect_equal(safe_html("<javascript:alert(1)>\n"), "<p><a href=\"\">javascript:alert(1)</a></p>\n");
    expect_equal(safe_html("[x]\n\n[x]: vbscript:msgbox\n"), "<p><a href=\"\">x</a></p>\n");
    expect_equal(safe_html("![x](file:///etc/passwd)\n"), "<p><img src=\"\" alt=\"x\" /></p>\n");
    expect_equal(safe_html("[x](data:text/html,hi)\n"), "<p><a href=\"\">x</a></p>\n");
    expect_equal(
        safe_html("![x](data:image/png;base64,AA)\n"), "<p><img src=\"data:image/png;base64,AA\" alt=\"x\" /></p>\n"
    );
    expect_equal(
        safe_html("[x](https://example.com/a?b=1&c=2)\n"),
        "<p><a href=\"https://example.com/a?b=1&amp;c=2\">x</a></p>\n"
    );
    # Without safe mode the URL is kept.
    expect_equal(markdown.to_html("[x](javascript:alert(1))\n"), "<p><a href=\"javascript:alert(1)\">x</a></p>\n");
}

[Test]
filters_tags_with_gfm_only() {
    expect_equal(markdown.to_html("<iframe src=x></iframe>\n"), "&lt;iframe src=x>&lt;/iframe>\n");
    expect_equal(markdown.to_html("a <script>b</script>\n"), "<p>a &lt;script>b&lt;/script></p>\n");
    expect_equal(markdown.to_html("a <scripts>\n"), "<p>a <scripts></p>\n");
    expect_equal(markdown.to_html("a <style>\n", markdown.Options(gfm = false)), "<p>a <style></p>\n");
}

[Test]
gfm_extensions_turn_off() {
    var commonmark = markdown.Options(gfm = false);
    expect_equal(markdown.to_html("~~a~~ www.example.com\n", commonmark), "<p>~~a~~ www.example.com</p>\n");
    expect_equal(markdown.to_html("- [x] a\n", commonmark), "<ul>\n<li>[x] a</li>\n</ul>\n");
    expect_equal(markdown.to_html("| a |\n| - |\n", commonmark), "<p>| a |\n| - |</p>\n");
    expect_equal(
        markdown.to_html("~a~ www.example.com\n"),
        "<p><del>a</del> <a href=\"http://www.example.com\">www.example.com</a></p>\n"
    );
}

# GFM: a `www.` link starts at a line start, after whitespace or after one
# of `*`, `_`, `~` and `(`, so not right after a code span, link or tag.
[Test]
links_www_only_after_a_space_or_delimiter() {
    expect_equal(markdown.to_html("`a`www.example.com\n"), "<p><code>a</code>www.example.com</p>\n");
    expect_equal(markdown.to_html("[a](/b)www.example.com\n"), "<p><a href=\"/b\">a</a>www.example.com</p>\n");
    expect_equal(markdown.to_html("<i>www.example.com\n"), "<p><i>www.example.com</p>\n");
    var link = "<a href=\"http://www.example.com\">www.example.com</a>";
    expect_equal(markdown.to_html("`a` www.example.com\n"), $"<p><code>a</code> {link}</p>\n");
    expect_equal(markdown.to_html("*a*www.example.com\n"), $"<p><em>a</em>{link}</p>\n");
    expect_equal(markdown.to_html("*www.example.com*\n"), $"<p><em>{link}</em></p>\n");
    expect_equal(markdown.to_html("`a`\nwww.example.com\n"), $"<p><code>a</code>\n{link}</p>\n");
}

[Test]
renders_task_lists_and_tables() {
    expect_equal(
        markdown.to_html("- [ ] a\n\n- [x] b\n"),
        "<ul>\n<li>\n<p><input disabled=\"\" type=\"checkbox\"> a</p>\n</li>\n<li>\n<p><input checked=\"\" disabled=\"\" type=\"checkbox\"> b</p>\n</li>\n</ul>\n"
    );
    expect_equal(
        markdown.to_html("para\n| a | b |\n|:-|-:|\n| *1* |\n"),
        "<p>para</p>\n<table>\n<thead>\n<tr>\n<th align=\"left\">a</th>\n<th align=\"right\">b</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td align=\"left\"><em>1</em></td>\n<td align=\"right\"></td>\n</tr>\n</tbody>\n</table>\n"
    );
    # No autolinks inside links.
    expect_equal(markdown.to_html("[*www.a.com*](/b)\n"), "<p><a href=\"/b\"><em>www.a.com</em></a></p>\n");
}

[Test]
replaces_nul_and_reads_any_line_ending() {
    var bytes = "a".bytes();
    bytes.append(0);
    bytes.append('b');
    expect_equal(markdown.to_html(text.Utf8.decode(bytes).value()), "<p>a\u{FFFD}b</p>\n");
    expect_equal(markdown.to_html("a\r\nb\rc\n"), "<p>a\nb\nc</p>\n");
    expect_equal(markdown.to_html(""), "");
    expect_equal(markdown.to_html("# no final line ending"), "<h1>no final line ending</h1>\n");
}

[Test]
builds_the_tree() {
    var doc = markdown.parse("# A *b*\n\n1. [x](/u \"t\")\n2. `c`\n");
    expect_true(doc.kind == markdown.NodeKind.Document);
    expect_equal(doc.children.count, 2);
    var heading = doc.children[0];
    expect_true(heading.kind == markdown.NodeKind.Heading);
    expect_equal(heading.level, 1);
    expect_equal(heading.children[0].literal, "A ");
    expect_true(heading.children[1].kind == markdown.NodeKind.Emphasis);
    var list = doc.children[1];
    expect_true(list.ordered && list.tight);
    expect_equal(list.start, 1);
    var link = list.children[0].children[0].children[0];
    expect_true(link.kind == markdown.NodeKind.Link);
    expect_equal(link.destination, "/u");
    expect_equal(link.title, "t");
    expect_equal(list.children[1].children[0].children[0].literal, "c");
}

[Test]
walks_the_tree_as_events() {
    var kinds = Array<String>();
    for (var event in markdown.parse("a *b*\n").events()) {
        kinds.append((event.entering ? "+" : "-") + event.node.kind.name());
    }
    expect_equal(
        " ".join(kinds), "+Document +Paragraph +Text -Text +Emphasis +Text -Text -Emphasis -Paragraph -Document"
    );
}

[Test]
renders_a_tree_built_by_hand() {
    var doc = markdown.Node(markdown.NodeKind.Document);
    var paragraph = markdown.Node(markdown.NodeKind.Paragraph);
    var text = markdown.Node(markdown.NodeKind.Text);
    text.literal = "<hi>";
    paragraph.children.append(text);
    doc.children.append(paragraph);
    expect_equal(markdown.render_html(doc), "<p>&lt;hi&gt;</p>\n");
}

[Test]
survives_pathological_input() {
    # Each of these is quadratic in a naive parser, or nests deep enough to
    # overflow the stack; they finish at once.
    expect_true(markdown.to_html("*a **b ".repeat(20000)).size > 0);
    expect_true(markdown.to_html("`a ``b ".repeat(20000)).size > 0);
    expect_true(markdown.to_html("<!-- a ".repeat(20000)).size > 0);
    expect_true(markdown.to_html("[a](".repeat(20000)).size > 0);
    expect_true(markdown.to_html("[".repeat(20000) + "a" + "]".repeat(20000)).size > 0);
    expect_true(markdown.to_html("> ".repeat(20000) + "a\n").size > 0);
    expect_true(markdown.to_html("- ".repeat(20000) + "a\n").size > 0);
    expect_true(markdown.to_html("*".repeat(20000) + "a" + "*".repeat(20000)).size > 0);
    expect_true(markdown.to_html("![".repeat(20000) + "a" + "](b)".repeat(20000)).size > 0);
}

[Test]
caps_nesting_at_256_levels() {
    var doc = markdown.parse("> ".repeat(300) + "a\n");
    var depth = 0;
    var node = doc;
    while (!node.children.is_empty && node.children[0].kind == markdown.NodeKind.BlockQuote) {
        node = node.children[0];
        depth += 1;
    }
    expect_equal(depth, 255);
    expect_true(node.children[0].kind == markdown.NodeKind.Paragraph);
}

[Test]
handles_inputs_found_by_fuzzing() {
    # Multi-byte text where a fixed-length match is tried, and a table
    # under a paragraph that was all link reference definitions.
    expect_equal(markdown.to_html("wé"), "<p>wé</p>\n");
    expect_equal(markdown.to_html("<wé"), "<p>&lt;wé</p>\n");
    expect_equal(markdown.to_html("<a@é>"), "<p>&lt;a@é&gt;</p>\n");
    expect_equal(
        markdown.to_html("| é | b |\n| - | - |\n"),
        "<table>\n<thead>\n<tr>\n<th>é</th>\n<th>b</th>\n</tr>\n</thead>\n</table>\n"
    );
    # As in commonmark.js, the line after the definitions continues their
    # paragraph, as the spec's `[foo]: /url` then `===` example shows.
    expect_equal(markdown.to_html("[a]: /u\n- \n"), "<p>-</p>\n");
}
