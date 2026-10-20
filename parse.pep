## Parsing: `Options`, and `parse`, which reads Markdown into a tree of
## `Node`s. The block structure is read line by line, as the CommonMark
## spec describes, and then each paragraph's, heading's and table cell's
## text is parsed into inlines.

import "characters";
import "inlines";
import "node";

## What `parse`, `render_html` and `to_html` do beyond CommonMark.
export struct Options {
    ## Whether the GitHub Flavored Markdown extensions are on: tables, task
    ## list items, strikethrough, extended autolinks (`www.`, `https://`,
    ## emails), and the tag filter, which escapes the `<` of tags such as
    ## `<script>` and `<iframe>` in raw HTML.
    var gfm: bool;
    ## Whether the HTML is safe to show from an untrusted writer: raw HTML
    ## is dropped, and a link or image to a `javascript:`, `vbscript:`,
    ## `file:` or (other than an image's) `data:` URL gets an empty URL.
    var safe: bool;

    ## Makes options.
    ##
    ## @param gfm whether the GFM extensions are on
    ## @param safe whether raw HTML and dangerous URLs are dropped
    construct(gfm: bool = true, safe: bool = false) {
        this.gfm = gfm;
        this.safe = safe;
    }
}

## Parses `markdown` into a tree: a `Document` node whose children are the
## top-level blocks. Any text is Markdown, so parsing never fails.
##
## Link reference definitions are resolved, so links that use them carry
## their destination; the definitions themselves leave no node.
##
## @param markdown the text to parse
## @param options the extensions to use
## @returns the document's root
## @example
##     import markdown;
##
##     main(): int {
##         var doc = markdown.parse("- [x] done\n- [ ] to do\n");
##         var list = doc.children[0];
##         assert(list.kind == markdown.NodeKind.List && list.tight, "a tight list");
##         assert(list.children[0].task && list.children[0].checked, "a checked task");
##         return 0;
##     }
export parse(markdown: String, options: Options = Options()): Node {
    var parser = _BlockParser(options);
    var start: ulong = 0;
    var index: ulong = 0;
    while (index < markdown.size) {
        var c = markdown.byte_at(index);
        if (c == '\n' || c == '\r') {
            parser._incorporate_line(markdown.substr_bytes(start, index - start));
            if (c == '\r' && index + 1 < markdown.size && markdown.byte_at(index + 1) == '\n') {
                index += 1;
            }
            start = index + 1;
        }
        index += 1;
    }
    if (start < markdown.size) {
        parser._incorporate_line(markdown.substr_bytes(start, markdown.size - start));
    }
    while (!parser._open.is_empty) {
        parser._finalize(parser._open.last(), parser._line_number);
    }
    _parse_inlines_of(parser._document.node, parser._references, options);
    return parser._document.node;
}

# A link reference definition's target.
struct _Reference {
    var destination: String;
    var title: String;

    construct(destination: String, title: String) {
        this.destination = destination;
        this.title = title;
    }
}

# A block being parsed: its node, and what the parser needs to know about
# it until it closes.
struct _Block {
    var node: Node;
    var children: Array<_Block>;
    # The lines of a paragraph, heading, code block or HTML block.
    var content: StringBuilder;
    # The lines the block starts and ends on, from 1.
    var start_line: ulong;
    var end_line: ulong;
    # A list's or item's marker: the bullet, or an ordered list's `.` or `)`.
    var marker: u8;
    # An item's marker's column, and its width with the spaces after it.
    var marker_offset: ulong;
    var padding: ulong;
    # A fenced code block's fence: its character, length and indentation.
    var fenced: bool;
    var fence_char: u8;
    var fence_length: ulong;
    var fence_offset: ulong;
    # An HTML block's kind, 1 to 7, as the spec numbers its start conditions.
    var html_kind: int;
    # A table's column alignments.
    var alignments: Array<Alignment>;

    construct(kind: NodeKind, line: ulong) {
        node = Node(kind);
        children = Array<_Block>();
        content = StringBuilder();
        start_line = line;
        end_line = line;
        alignments = Array<Alignment>();
    }
}

# The block parser: commonmark.js's algorithm. Each line first continues
# the open blocks it can, then may start new ones, and what is left is
# added to the innermost block as text.
struct _BlockParser {
    var _options: Options;
    var _document: _Block;
    # The open blocks, outermost first: the document, then each open
    # block's last child.
    var _open: Array<_Block>;
    var _references: HashMap<String, _Reference>;
    # The current line, its number, and where in it the parser is: a byte
    # offset and a column (tabs stop every 4 columns).
    var _line: String;
    var _line_number: ulong;
    var _offset: ulong;
    var _column: ulong;
    # The next byte that is not a space or tab, its column, and its
    # indentation from the current column.
    var _next_nonspace: ulong;
    var _next_nonspace_column: ulong;
    var _indent: ulong;
    var _indented: bool;
    var _blank: bool;
    var _partially_consumed_tab: bool;
    var _all_closed: bool;
    var _last_matched: _Block;
    var _old_tip: _Block;

    construct(options: Options) {
        _options = options;
        _document = _Block(NodeKind.Document, 1);
        _open = [_document];
        _references = HashMap<String, _Reference>();
        _line = "";
    }

    _tip(): _Block {
        return _open.last();
    }

    # The byte at `index` of the line, or -1 past its end.
    _peek(index: ulong): int {
        return index < _line.size ? _line.byte_at(index) as int : -1;
    }

    _rest(from: ulong): String {
        return from < _line.size ? _line.substr_bytes(from, _line.size - from) : "";
    }

    _find_next_nonspace() {
        var index = _offset;
        var columns = _column;
        while (index < _line.size) {
            var c = _line.byte_at(index);
            if (c == ' ') {
                index += 1;
                columns += 1;
            } else if (c == '\t') {
                index += 1;
                columns += 4 - columns % 4;
            } else {
                break;
            }
        }
        _blank = index >= _line.size;
        _next_nonspace = index;
        _next_nonspace_column = columns;
        _indent = _next_nonspace_column - _column;
        _indented = _indent >= 4;
    }

    _advance_next_nonspace() {
        _offset = _next_nonspace;
        _column = _next_nonspace_column;
        _partially_consumed_tab = false;
    }

    # Moves `count` bytes on, or with `columns`, `count` columns, which may
    # end inside a tab.
    _advance_offset(count: ulong, columns: bool) {
        var left = count;
        while (left > 0 && _offset < _line.size) {
            if (_line.byte_at(_offset) == '\t') {
                var to_tab = 4 - _column % 4;
                if (columns) {
                    _partially_consumed_tab = to_tab > left;
                    var advance = to_tab > left ? left : to_tab;
                    _column += advance;
                    if (!_partially_consumed_tab) {
                        _offset += 1;
                    }
                    left -= advance;
                } else {
                    _partially_consumed_tab = false;
                    _column += to_tab;
                    _offset += 1;
                    left -= 1;
                }
            } else {
                _partially_consumed_tab = false;
                _offset += 1;
                _column += 1;
                left -= 1;
            }
        }
    }

    _advance_to_end() {
        _advance_offset(_line.size - _offset, false);
    }

    # Adds the rest of the line to the innermost block's text.
    _add_line() {
        var tip = _tip();
        if (_partially_consumed_tab) {
            _offset += 1;
            tip.content.append(" ".repeat(4 - _column % 4));
        }
        tip.content.append(_rest(_offset));
        tip.content.append("\n");
    }

    # Opens a block of `kind` in the innermost block that can hold it,
    # closing those that cannot.
    _add_child(kind: NodeKind): _Block {
        while (!_can_contain(_tip().node.kind, kind)) {
            _finalize(_tip(), _line_number - 1);
        }
        var block = _Block(kind, _line_number);
        _tip().children.append(block);
        _tip().node.children.append(block.node);
        _open.append(block);
        return block;
    }

    # Closes the blocks the current line did not continue.
    _close_unmatched_blocks() {
        if (!_all_closed) {
            while (_tip() !== _last_matched) {
                _finalize(_tip(), _line_number - 1);
            }
            _all_closed = true;
        }
    }

    # Removes the innermost block, which has just opened, from its parent.
    _discard_tip() {
        _open.pop();
        _tip().children.pop();
        _tip().node.children.pop();
    }

    _incorporate_line(text: String) {
        _old_tip = _tip();
        _offset = 0;
        _column = 0;
        _blank = false;
        _partially_consumed_tab = false;
        _line_number += 1;
        _line = text.contains("\0") ? text.replace("\0", "\u{FFFD}") : text;

        var container = _document;
        var depth: ulong = 1;
        while (depth < _open.count) {
            var block = _open[depth];
            _find_next_nonspace();
            var result = _continue(block);
            if (result == 2) {
                return;
            }
            if (result == 1) {
                break;
            }
            container = block;
            depth += 1;
        }
        _all_closed = container === _old_tip;
        _last_matched = container;

        var kind = container.node.kind;
        var matched_leaf = kind == NodeKind.CodeBlock || kind == NodeKind.HtmlBlock;
        while (!matched_leaf) {
            _find_next_nonspace();
            if (!_indented && !_maybe_special(_peek(_next_nonspace))) {
                _advance_next_nonspace();
                break;
            }
            var result = _start_block(container);
            if (result == 0) {
                _advance_next_nonspace();
                break;
            }
            container = _tip();
            matched_leaf = result == 2;
        }

        if (!_all_closed && !_blank && _tip().node.kind == NodeKind.Paragraph) {
            # A lazy continuation line.
            _add_line();
            return;
        }
        _close_unmatched_blocks();
        kind = container.node.kind;
        if (kind == NodeKind.Paragraph || kind == NodeKind.CodeBlock || kind == NodeKind.HtmlBlock) {
            _add_line();
            if (kind == NodeKind.HtmlBlock
                && container.html_kind <= 5
                && _html_block_ends(container.html_kind, _rest(_offset))) {
                _finalize(container, _line_number);
            }
        } else if (kind == NodeKind.Table) {
            if (_offset < _line.size) {
                _add_table_row(container, _rest(_offset), false);
            }
        } else if (_offset < _line.size && !_blank) {
            _add_child(NodeKind.Paragraph);
            _advance_next_nonspace();
            _add_line();
        }
    }

    # Whether a line whose first non-space byte is `c` may start a block
    # other than a paragraph.
    _maybe_special(c: int): bool {
        return c == '#'
            || c == '`'
            || c == '~'
            || c == '*'
            || c == '+'
            || c == '_'
            || c == '='
            || c == '<'
            || c == '>'
            || c == '-'
            || (c >= '0' && c <= '9')
            || (_options.gfm && (c == '|' || c == ':'));
    }

    # Continues an open block with the current line: 0 when the line
    # continues it, 1 when it does not, 2 when the line is used up.
    _continue(block: _Block): int {
        var kind = block.node.kind;
        if (kind == NodeKind.BlockQuote) {
            if (_indented || _peek(_next_nonspace) != '>') {
                return 1;
            }
            _advance_next_nonspace();
            _advance_offset(1, false);
            if (_is_space_or_tab(_peek(_offset))) {
                _advance_offset(1, true);
            }
            return 0;
        }
        if (kind == NodeKind.Item) {
            if (_blank) {
                if (block.children.is_empty) {
                    return 1;
                }
                _advance_next_nonspace();
            } else if (_indent >= block.marker_offset + block.padding) {
                _advance_offset(block.marker_offset + block.padding, true);
            } else {
                return 1;
            }
            return 0;
        }
        if (kind == NodeKind.CodeBlock) {
            if (block.fenced) {
                if (_indent <= 3 && _peek(_next_nonspace) == block.fence_char) {
                    var end = _next_nonspace;
                    while (_peek(end) == block.fence_char) {
                        end += 1;
                    }
                    var rest = end;
                    while (_is_space_or_tab(_peek(rest))) {
                        rest += 1;
                    }
                    if (end - _next_nonspace >= block.fence_length && rest >= _line.size) {
                        _finalize(block, _line_number);
                        return 2;
                    }
                }
                var skip = block.fence_offset;
                while (skip > 0 && _is_space_or_tab(_peek(_offset))) {
                    _advance_offset(1, true);
                    skip -= 1;
                }
                return 0;
            }
            if (_indent >= 4) {
                _advance_offset(4, true);
            } else if (_blank) {
                _advance_next_nonspace();
            } else {
                return 1;
            }
            return 0;
        }
        if (kind == NodeKind.HtmlBlock) {
            return _blank && block.html_kind >= 6 ? 1 : 0;
        }
        if (kind == NodeKind.Paragraph || kind == NodeKind.Table) {
            return _blank ? 1 : 0;
        }
        if (kind == NodeKind.List) {
            return 0;
        }
        return 1;
    }

    # Tries each kind of block start in turn: 0 when none starts, 1 for a
    # container block, 2 for a leaf block.
    _start_block(container: _Block): int {
        var c = _peek(_next_nonspace);
        if (!_indented) {
            if (c == '>' && _open.count < _MAX_DEPTH) {
                _advance_next_nonspace();
                _advance_offset(1, false);
                if (_is_space_or_tab(_peek(_offset))) {
                    _advance_offset(1, true);
                }
                _close_unmatched_blocks();
                _add_child(NodeKind.BlockQuote);
                return 1;
            }
            if (c == '#' && _start_atx_heading()) {
                return 2;
            }
            if ((c == '`' || c == '~') && _start_fenced_code()) {
                return 2;
            }
            if (c == '<' && _start_html_block(container)) {
                return 2;
            }
            if (container.node.kind == NodeKind.Paragraph && (c == '=' || c == '-')) {
                var result = _start_setext_heading(container);
                if (result != 0) {
                    return result;
                }
            }
            if ((c == '*' || c == '_' || c == '-') && _is_thematic_break(_rest(_next_nonspace))) {
                _close_unmatched_blocks();
                _add_child(NodeKind.ThematicBreak);
                _advance_to_end();
                return 2;
            }
        }
        if ((!_indented || container.node.kind == NodeKind.List)
            && _open.count + 1 < _MAX_DEPTH
            && _start_list_item(container)) {
            return 1;
        }
        if (_indented && _tip().node.kind != NodeKind.Paragraph && !_blank) {
            _advance_offset(4, true);
            _close_unmatched_blocks();
            _add_child(NodeKind.CodeBlock);
            return 2;
        }
        if (_options.gfm && !_indented && container.node.kind == NodeKind.Paragraph && _start_table(container)) {
            return 2;
        }
        return 0;
    }

    _start_atx_heading(): bool {
        var end = _next_nonspace;
        while (_peek(end) == '#') {
            end += 1;
        }
        var level = end - _next_nonspace;
        if (level > 6 || !(end >= _line.size || _is_space_or_tab(_peek(end)))) {
            return false;
        }
        _close_unmatched_blocks();
        var block = _add_child(NodeKind.Heading);
        block.node.level = level as int;
        # The text, without the closing sequence of `#`s.
        var content = _trim(_rest(end));
        var hashes = content.size;
        while (hashes > 0 && content.byte_at(hashes - 1) == '#') {
            hashes -= 1;
        }
        if (hashes == 0) {
            content = "";
        } else if (hashes < content.size && _is_space_or_tab(content.byte_at(hashes - 1))) {
            content = _trim(content.substr_bytes(0, hashes));
        }
        block.content.append(content);
        _advance_to_end();
        return true;
    }

    _start_fenced_code(): bool {
        var c = _line.byte_at(_next_nonspace);
        var end = _next_nonspace;
        while (_peek(end) == c) {
            end += 1;
        }
        var length = end - _next_nonspace;
        if (length < 3 || (c == '`' && _rest(end).contains("`"))) {
            return false;
        }
        _close_unmatched_blocks();
        var block = _add_child(NodeKind.CodeBlock);
        block.fenced = true;
        block.fence_char = c;
        block.fence_length = length;
        block.fence_offset = _indent;
        _advance_next_nonspace();
        _advance_offset(length, false);
        return true;
    }

    _start_html_block(container: _Block): bool {
        var rest = _rest(_next_nonspace);
        for (var kind in 1..8) {
            if (!_html_block_starts(kind, rest)) {
                continue;
            }
            if (kind == 7
                && (container.node.kind == NodeKind.Paragraph
                    || (!_all_closed && !_blank && _tip().node.kind == NodeKind.Paragraph))) {
                return false;
            }
            _close_unmatched_blocks();
            # The spaces before the tag are part of the block.
            var block = _add_child(NodeKind.HtmlBlock);
            block.html_kind = kind;
            return true;
        }
        return false;
    }

    _start_setext_heading(container: _Block): int {
        var rest = _rest(_next_nonspace);
        var c = rest.byte_at(0);
        var end: ulong = 0;
        while (end < rest.size && rest.byte_at(end) == c) {
            end += 1;
        }
        if (_trim(rest.substr_bytes(end, rest.size - end)) != "") {
            return 0;
        }
        _close_unmatched_blocks();
        var content = _take_references(container.content.to_string());
        container.content = StringBuilder();
        container.content.append(content);
        if (_trim(content) == "") {
            return 0;
        }
        container.node.kind = NodeKind.Heading;
        container.node.level = c == '=' ? 1 : 2;
        _advance_to_end();
        return 2;
    }

    _start_list_item(container: _Block): bool {
        if (_indent >= 4) {
            return false;
        }
        var c = _peek(_next_nonspace);
        var marker_end = _next_nonspace;
        var ordered = false;
        var start = 0;
        var marker: u8 = 0;
        if (c == '*' || c == '+' || c == '-') {
            marker = c as u8;
            marker_end += 1;
        } else {
            while (marker_end - _next_nonspace < 9 && _peek(marker_end) >= '0' && _peek(marker_end) <= '9') {
                marker_end += 1;
            }
            var delimiter = _peek(marker_end);
            if (marker_end == _next_nonspace || (delimiter != '.' && delimiter != ')')) {
                return false;
            }
            start = int.parse(_line.substr_bytes(_next_nonspace, marker_end - _next_nonspace)).value();
            if (container.node.kind == NodeKind.Paragraph && start != 1) {
                return false;
            }
            ordered = true;
            marker = delimiter as u8;
            marker_end += 1;
        }
        var after = _peek(marker_end);
        if (!(after == -1 || _is_space_or_tab(after))) {
            return false;
        }
        if (container.node.kind == NodeKind.Paragraph && _trim(_rest(marker_end)) == "") {
            return false;
        }
        var marker_offset = _indent;
        var marker_width = marker_end - _next_nonspace;
        _advance_next_nonspace();
        _advance_offset(marker_width, true);
        var spaces_start_column = _column;
        var spaces_start_offset = _offset;
        while (true) {
            _advance_offset(1, true);
            if (!(_column - spaces_start_column < 5 && _is_space_or_tab(_peek(_offset)))) {
                break;
            }
        }
        var spaces = _column - spaces_start_column;
        var padding = marker_width + spaces;
        if (spaces >= 5 || spaces < 1 || _offset >= _line.size) {
            padding = marker_width + 1;
            _column = spaces_start_column;
            _offset = spaces_start_offset;
            if (_is_space_or_tab(_peek(_offset))) {
                _advance_offset(1, true);
            }
        }
        _close_unmatched_blocks();
        var tip = _tip();
        if (tip.node.kind != NodeKind.List || tip.node.ordered != ordered || tip.marker != marker) {
            var list = _add_child(NodeKind.List);
            list.node.ordered = ordered;
            list.node.start = start;
            list.node.tight = true;
            list.marker = marker;
        }
        var item = _add_child(NodeKind.Item);
        item.marker = marker;
        item.marker_offset = marker_offset;
        item.padding = padding;
        return true;
    }

    # Starts a GFM table when the line is a delimiter row (`| --- | :-: |`)
    # under a paragraph whose last line has as many cells.
    _start_table(container: _Block): bool {
        var alignments = _table_alignments(_rest(_next_nonspace));
        if (alignments.is_empty) {
            return false;
        }
        var content = container.content.to_string();
        if (content.is_empty) {
            # Its text was all link reference definitions.
            return false;
        }
        content = content.substr_bytes(0, content.size - 1);
        var last_break = content.rfind("\n");
        var header = last_break < 0 ?
            content :
            content.substr_bytes((last_break as ulong) + 1, content.size - (last_break as ulong) - 1);
        if (_table_cells(header).count != alignments.count) {
            return false;
        }
        _close_unmatched_blocks();
        if (last_break < 0) {
            _discard_tip();
        } else {
            container.content = StringBuilder();
            container.content.append(content.substr_bytes(0, (last_break as ulong) + 1));
            _finalize(container, _line_number - 2);
        }
        var table = _add_child(NodeKind.Table);
        table.start_line = _line_number - 1;
        table.alignments = alignments;
        _add_table_row(table, header, true);
        _advance_to_end();
        return true;
    }

    _add_table_row(table: _Block, text: String, header: bool) {
        var cells = _table_cells(text);
        var row = Node(NodeKind.TableRow);
        row.header = header;
        for (var index in 0..table.alignments.count) {
            var cell = Node(NodeKind.TableCell);
            cell.alignment = table.alignments[index];
            if (index < cells.count) {
                cell.literal = cells[index];
            }
            row.children.append(cell);
        }
        table.node.children.append(row);
        table.end_line = _line_number;
    }

    # Closes `block`, the innermost open block, at line `line`.
    _finalize(block: _Block, line: ulong) {
        _open.pop();
        block.end_line = line;
        var kind = block.node.kind;
        if (kind == NodeKind.Paragraph) {
            var content = _take_references(block.content.to_string());
            if (_trim(content) == "") {
                _tip().children.pop();
                _tip().node.children.pop();
            } else {
                block.node.literal = content;
            }
        } else if (kind == NodeKind.Heading) {
            block.node.literal = block.content.to_string();
        } else if (kind == NodeKind.CodeBlock) {
            var content = block.content.to_string();
            if (block.fenced) {
                var first_break = content.find("\n") as ulong;
                block.node.info = _unescape(_trim(content.substr_bytes(0, first_break)));
                block.node.literal = content.substr_bytes(first_break + 1, content.size - first_break - 1);
            } else {
                # Drop the trailing blank lines.
                var lines = content.split("\n");
                while (!lines.is_empty && _trim(lines.last()) == "") {
                    lines.pop();
                }
                block.node.literal = "\n".join(lines) + "\n";
            }
        } else if (kind == NodeKind.HtmlBlock) {
            var content = block.content.to_string();
            var end = content.size;
            while (end > 0 && (content.byte_at(end - 1) == '\n' || content.byte_at(end - 1) == ' ')) {
                end -= 1;
            }
            # Keep the spaces that end the last line of text.
            var line_end = content.find("\n", end);
            block.node.literal = content.substr_bytes(0, line_end < 0 ? end : line_end as ulong);
        } else if (kind == NodeKind.Item) {
            block.end_line = block.children.is_empty ? block.start_line : block.children.last().end_line;
        } else if (kind == NodeKind.List) {
            block.end_line = block.children.last().end_line;
            block.node.tight = !_has_gap(block.children);
            for (var item in block.children) {
                if (_has_gap(item.children)) {
                    block.node.tight = false;
                }
            }
        }
    }

    # Takes the link reference definitions from the start of a paragraph's
    # text, and returns what is left.
    _take_references(content: String): String {
        var rest = content;
        while (rest.starts_with("[")) {
            var length = _parse_reference(rest, _references, _options);
            if (length == 0) {
                break;
            }
            rest = rest.substr_bytes(length, rest.size - length);
        }
        return rest;
    }
}

# The deepest a tree may nest, in blocks and, separately, in inlines:
# deeper quotes and lists are read as text, and deeper emphasis and links
# as their delimiters, since releasing a much deeper tree overflows the
# stack.
# shortcut: nesting past 256 is lost; lift the cap once pep-lang/pepper#65
# releases deep trees without recursing.
const _MAX_DEPTH = 256;

# Whether a blank line separates any two blocks of `blocks`.
private _has_gap(blocks: Array<_Block>): bool {
    for (var index in 1..blocks.count) {
        if (blocks[index - 1].end_line + 1 != blocks[index].start_line) {
            return true;
        }
    }
    return false;
}

private _can_contain(parent: NodeKind, child: NodeKind): bool {
    if (parent == NodeKind.Document || parent == NodeKind.BlockQuote || parent == NodeKind.Item) {
        return child != NodeKind.Item;
    }
    return parent == NodeKind.List && child == NodeKind.Item;
}

# `s` without the spaces, tabs and line endings at its ends.
_trim(s: String): String {
    var start: ulong = 0;
    var end = s.size;
    while (start < end && _is_ascii_whitespace(s.byte_at(start))) {
        start += 1;
    }
    while (end > start && _is_ascii_whitespace(s.byte_at(end - 1))) {
        end -= 1;
    }
    return start == 0 && end == s.size ? s : s.substr_bytes(start, end - start);
}

# Whether `s` is a thematic break: three or more `*`, `-` or `_`, the same
# one, with only spaces and tabs between and after them.
private _is_thematic_break(s: String): bool {
    var c = s.byte_at(0);
    var count = 0;
    for (var index in 0..s.size) {
        var d = s.byte_at(index);
        if (d == c) {
            count += 1;
        } else if (!_is_space_or_tab(d)) {
            return false;
        }
    }
    return count >= 3;
}

# The cells of a table row: split at the `|`s that are not escaped, with
# the row's outer `|`s dropped, each trimmed, and `\|` read as `|`.
private _table_cells(row: String): Array<String> {
    var text = _trim(row);
    var cells = Array<String>();
    var index: ulong = text.starts_with("|") ? 1 : 0;
    var cell = StringBuilder();
    var run_start = index;
    var open = false;
    while (index < text.size) {
        var c = text.byte_at(index);
        if (c == '\\' && index + 1 < text.size && text.byte_at(index + 1) == '|') {
            cell.append(text.substr_bytes(run_start, index - run_start));
            cell.append("|");
            index += 2;
            run_start = index;
            open = true;
            continue;
        }
        if (c == '|') {
            cell.append(text.substr_bytes(run_start, index - run_start));
            cells.append(_trim(cell.to_string()));
            cell = StringBuilder();
            run_start = index + 1;
            open = false;
        } else {
            open = true;
        }
        index += 1;
    }
    if (open || cells.is_empty) {
        cell.append(text.substr_bytes(run_start, text.size - run_start));
        cells.append(_trim(cell.to_string()));
    }
    return cells;
}

# The alignments of a table's delimiter row, or none when `row` is not one.
private _table_alignments(row: String): Array<Alignment> {
    var alignments = Array<Alignment>();
    if (!row.contains("-")) {
        return alignments;
    }
    for (var cell in _table_cells(row)) {
        var left = cell.starts_with(":");
        var right = cell.ends_with(":");
        var dashes = cell.substr_bytes(left ? 1 : 0, cell.size - (left ? 1 : 0) - (right && cell.size > 1 ? 1 : 0));
        if (dashes.is_empty || dashes.replace("-", "") != "") {
            return Array<Alignment>();
        }
        alignments.append(
            left && right ? Alignment.Center : left ? Alignment.Left : right ? Alignment.Right : Alignment.None
        );
    }
    return alignments;
}

# Whether `s`, which starts at a `<`, opens an HTML block of `kind`.
private _html_block_starts(kind: int, s: String): bool {
    if (kind == 1) {
        for (var name in ["script", "pre", "textarea", "style"]) {
            if (_starts_with_name(s, 1, name)) {
                var after = s.size > name.size + 1 ? s.byte_at(name.size + 1) as int : -1;
                return after == -1 || after == '>' || _is_ascii_whitespace(after);
            }
        }
        return false;
    }
    if (kind == 2) {
        return s.starts_with("<!--");
    }
    if (kind == 3) {
        return s.starts_with("<?");
    }
    if (kind == 4) {
        return s.size > 2 && s.byte_at(1) == '!' && s.byte_at(2).is_alphabetic();
    }
    if (kind == 5) {
        return s.starts_with("<![CDATA[");
    }
    if (kind == 6) {
        var start: ulong = s.size > 1 && s.byte_at(1) == '/' ? 2 : 1;
        var end = start;
        while (end < s.size && s.byte_at(end).is_alphanumeric()) {
            end += 1;
        }
        if (!_HTML_BLOCK_NAMES.contains(" " + s.substr_bytes(start, end - start).lower() + " ") || end == start) {
            return false;
        }
        if (end >= s.size || _is_ascii_whitespace(s.byte_at(end)) || s.byte_at(end) == '>') {
            return true;
        }
        return s.byte_at(end) == '/' && end + 1 < s.size && s.byte_at(end + 1) == '>';
    }
    var length = _scan_open_or_closing_tag(s, 0);
    if (length == 0 || _trim(s.substr_bytes(length, s.size - length)) != "") {
        return false;
    }
    var name_start: ulong = s.byte_at(1) == '/' ? 2 : 1;
    for (var name in ["script", "pre", "textarea", "style"]) {
        if (_starts_with_name(s, name_start, name)) {
            var after = s.byte_at(name_start + name.size);
            if (!after.is_alphanumeric() && after != '-') {
                return false;
            }
        }
    }
    return true;
}

# Whether `s` holds the end of an HTML block of `kind` (1 to 5).
private _html_block_ends(kind: int, s: String): bool {
    if (kind == 1) {
        var lower = s.lower();
        return lower.contains("</script>")
            || lower.contains("</pre>")
            || lower.contains("</textarea>")
            || lower.contains("</style>");
    }
    if (kind == 2) {
        return s.contains("-->");
    }
    if (kind == 3) {
        return s.contains("?>");
    }
    if (kind == 4) {
        return s.contains(">");
    }
    return s.contains("]]>");
}

# Whether `s` holds `name` at byte `at`, in any case.
private _starts_with_name(s: String, at: ulong, name: String): bool {
    if (s.size < at + name.size) {
        return false;
    }
    for (var index in 0..name.size) {
        if (s.byte_at(at + index).to_lower() != name.byte_at(index)) {
            return false;
        }
    }
    return true;
}

const _HTML_BLOCK_NAMES = " address article aside base basefont blockquote body caption center col colgroup dd details dialog dir div dl dt fieldset figcaption figure footer form frame frameset h1 h2 h3 h4 h5 h6 head header hr html iframe legend li link main menu menuitem nav noframes ol optgroup option p param search section summary table tbody td tfoot th thead title tr track ul ";
