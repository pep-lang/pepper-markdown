## The inline parser: code spans, emphasis, links, images, autolinks, raw
## HTML, entities and line breaks, from a block's text; and the link
## reference definitions at the start of a paragraph.

import "autolink";
import "characters";
import "node";
import "parse";

# Parses the text of each paragraph, heading and table cell under `root`
# into its inline children.
_parse_inlines_of(root: Node, references: HashMap<String, _Reference>, options: Options) {
    # The walk lists the nodes before any is parsed; parsing gives
    # childless nodes children, so the list stays right.
    for (var event in root.events()) {
        var node = event.node;
        if (!event.entering) {
            continue;
        }
        if (node.kind == NodeKind.Item && options.gfm) {
            _take_task_marker(node);
        } else if (node.kind == NodeKind.Paragraph
            || node.kind == NodeKind.Heading
            || node.kind == NodeKind.TableCell) {
            var parser = _InlineParser(_trim(node.literal), references, options);
            node.children = parser._parse();
            node.literal = "";
        }
    }
}

# Makes `item` a task list item when its first paragraph starts with
# `[ ]`, `[x]` or `[X]` and a space.
private _take_task_marker(item: Node) {
    if (item.children.is_empty || item.children[0].kind != NodeKind.Paragraph) {
        return;
    }
    var paragraph = item.children[0];
    var text = paragraph.literal;
    if (text.size < 4 || text.byte_at(0) != '[' || text.byte_at(2) != ']' || !_is_ascii_whitespace(text.byte_at(3))) {
        return;
    }
    var mark = text.byte_at(1);
    if (mark != ' ' && mark != 'x' && mark != 'X') {
        return;
    }
    item.task = true;
    item.checked = mark != ' ';
    paragraph.literal = text.substr_bytes(3, text.size - 3);
}

# Reads the link reference definition at the start of `text` into
# `references` (unless its label is defined already).
#
# Returns the bytes the definition takes, or 0 when `text` does not start
# with one.
_parse_reference(text: String, references: HashMap<String, _Reference>, options: Options): ulong {
    var parser = _InlineParser(text, references, options);
    var label_length = parser._parse_link_label();
    if (label_length == 0 || parser._peek() != ':') {
        return 0;
    }
    var label = text.substr_bytes(0, label_length);
    parser._position += 1;
    parser._skip_spaces_and_newline();
    var destination = parser._parse_link_destination();
    if (destination.is_empty()) {
        return 0;
    }
    var before_title = parser._position;
    parser._skip_spaces_and_newline();
    var title = Optional<String>.Empty;
    if (parser._position != before_title) {
        title = parser._parse_link_title();
    }
    if (title.is_empty()) {
        parser._position = before_title;
    }
    if (!parser._at_line_end()) {
        if (title.is_empty()) {
            return 0;
        }
        # The title is not alone on its line: the definition ends before it.
        title = Optional<String>.Empty;
        parser._position = before_title;
        if (!parser._at_line_end()) {
            return 0;
        }
    }
    var key = _normalize_label(label);
    if (key == "") {
        return 0;
    }
    if (!references.contains(key)) {
        references.insert(key, _Reference(destination.value(), title.value_or("")));
    }
    return parser._position;
}

# An inline node, in the list the parser builds before it gives a block
# its children.
struct _Piece {
    var node: Node;
    var previous: _Piece;
    var next: _Piece;
    # The height of the node's tree: 1 for a node without children.
    var height: int;

    construct(node: Node, height: int = 1) {
        this.node = node;
        this.height = height;
    }
}

# A run of `*`, `_` or `~` that may open or close emphasis.
struct _Delimiter {
    var character: u8;
    # How many of the run's characters are still unused, and how many it had.
    var count: ulong;
    var original_count: ulong;
    var piece: _Piece;
    var can_open: bool;
    var can_close: bool;
    var previous: _Delimiter;
    var next: _Delimiter;
}

# A `[` or `![` that may start a link or image.
struct _Bracket {
    var piece: _Piece;
    var previous: _Bracket;
    # The delimiter on top of the stack when the bracket was read.
    var previous_delimiter: _Delimiter;
    # Where the `[` is in the text.
    var index: ulong;
    var image: bool;
    var active: bool;
    # Whether another `[` came after this one.
    var bracket_after: bool;
}

# commonmark.js's inline parser, over one block's text.
struct _InlineParser {
    var _subject: String;
    var _position: ulong;
    var _references: HashMap<String, _Reference>;
    var _options: Options;
    var _first: _Piece;
    var _last: _Piece;
    var _delimiters: _Delimiter;
    var _brackets: _Bracket;
    # Lengths of backtick runs, and closings of raw HTML, known to appear
    # nowhere after the current position, so a text full of openers is not
    # searched again and again.
    var _missing_backticks: HashSet<ulong>;
    var _missing_closings: HashSet<String>;

    construct(subject: String, references: HashMap<String, _Reference>, options: Options) {
        _subject = subject;
        _references = references;
        _options = options;
        _missing_backticks = HashSet<ulong>();
        _missing_closings = HashSet<String>();
    }

    _peek(): int {
        return _position < _subject.size ? _subject.byte_at(_position) as int : -1;
    }

    _parse(): Array<Node> {
        while (_position < _subject.size) {
            _parse_inline();
        }
        _process_emphasis(__null);
        _brackets = __null;
        var nodes = _finish(_take_pieces(_first));
        _first = __null;
        _last = __null;
        return _options.gfm ? _autolinked(nodes) : nodes;
    }

    _parse_inline() {
        var c = _subject.byte_at(_position);
        var handled = false;
        if (c == '\n') {
            handled = _parse_newline();
        } else if (c == '\\') {
            handled = _parse_backslash();
        } else if (c == '`') {
            handled = _parse_backticks();
        } else if (c == '*' || c == '_' || (c == '~' && _options.gfm)) {
            handled = _parse_delimiters(c);
        } else if (c == '[') {
            _position += 1;
            _add_bracket(_append_text("["), _position - 1, false);
            handled = true;
        } else if (c == '!') {
            _position += 1;
            if (_peek() == '[') {
                _position += 1;
                _add_bracket(_append_text("!["), _position - 1, true);
            } else {
                _append_text("!");
            }
            handled = true;
        } else if (c == ']') {
            handled = _parse_close_bracket();
        } else if (c == '<') {
            handled = _parse_autolink() || _parse_html_tag();
        } else if (c == '&') {
            var entity = _entity_at(_subject, _position);
            if (entity.is_value()) {
                var (length, text) = entity.value();
                _position += length;
                _append_text(text);
                handled = true;
            }
        } else {
            var end = _position;
            while (end < _subject.size && !_is_special(_subject.byte_at(end))) {
                end += 1;
            }
            if (end > _position) {
                _append_text(_subject.substr_bytes(_position, end - _position));
                _position = end;
                handled = true;
            }
        }
        if (!handled) {
            _position += 1;
            _append_text(_subject.substr_bytes(_position - 1, 1));
        }
    }

    _is_special(c: u8): bool {
        return c == '\n'
            || c == '\\'
            || c == '`'
            || c == '*'
            || c == '_'
            || c == '['
            || c == '!'
            || c == ']'
            || c == '<'
            || c == '&'
            || (c == '~' && _options.gfm);
    }

    _append(node: Node): _Piece {
        var piece = _Piece(node);
        if (_last === __null) {
            _first = piece;
        } else {
            _last.next = piece;
            piece.previous = _last;
        }
        _last = piece;
        return piece;
    }

    _append_text(text: String): _Piece {
        var node = Node(NodeKind.Text);
        node.literal = text;
        return _append(node);
    }

    _unlink(piece: _Piece) {
        if (piece.previous === __null) {
            _first = piece.next;
        } else {
            piece.previous.next = piece.next;
        }
        if (piece.next === __null) {
            _last = piece.previous;
        } else {
            piece.next.previous = piece.previous;
        }
        piece.previous = __null;
        piece.next = __null;
    }

    # The height of the tallest piece after `piece` and before `end` (or
    # the last, when `end` is null).
    _height_between(piece: _Piece, end: _Piece): int {
        var height = 0;
        var current = piece.next;
        while (current !== __null && current !== end) {
            if (current.height > height) {
                height = current.height;
            }
            current = current.next;
        }
        return height;
    }

    # Moves the pieces after `piece` up to `end` (or to the last, when
    # `end` is null) into `parent`'s children.
    _move_after(piece: _Piece, end: _Piece, parent: Node) {
        var nodes = Array<Node>();
        var current = piece.next;
        while (current !== __null && current !== end) {
            var next = current.next;
            nodes.append(current.node);
            _unlink(current);
            current = next;
        }
        parent.children = _finish(nodes);
    }

    _parse_newline(): bool {
        _position += 1;
        var hard = false;
        if (_last !== __null && _last.node.kind == NodeKind.Text && _last.node.literal.ends_with(" ")) {
            var text = _last.node.literal;
            var end = text.size;
            while (end > 0 && text.byte_at(end - 1) == ' ') {
                end -= 1;
            }
            hard = text.size - end >= 2;
            _last.node.literal = text.substr_bytes(0, end);
        }
        _append(Node(hard ? NodeKind.LineBreak : NodeKind.SoftBreak));
        while (_is_space_or_tab(_peek())) {
            _position += 1;
        }
        return true;
    }

    _parse_backslash(): bool {
        _position += 1;
        var c = _peek();
        if (c == '\n') {
            _position += 1;
            _append(Node(NodeKind.LineBreak));
            while (_is_space_or_tab(_peek())) {
                _position += 1;
            }
        } else if (c != -1 && _is_ascii_punctuation(c)) {
            _append_text(_subject.substr_bytes(_position, 1));
            _position += 1;
        } else {
            _append_text("\\");
        }
        return true;
    }

    _parse_backticks(): bool {
        var start = _position;
        while (_peek() == '`') {
            _position += 1;
        }
        var length = _position - start;
        var after_open = _position;
        if (!_missing_backticks.contains(length)) {
            var search = after_open;
            while (true) {
                var found = _subject.find("`", search);
                if (found < 0) {
                    _missing_backticks.insert(length);
                    break;
                }
                var run_start = found as ulong;
                var run_end = run_start;
                while (run_end < _subject.size && _subject.byte_at(run_end) == '`') {
                    run_end += 1;
                }
                if (run_end - run_start == length) {
                    var content = _subject.substr_bytes(after_open, run_start - after_open).replace("\n", " ");
                    if (content.size >= 2
                        && content.starts_with(" ")
                        && content.ends_with(" ")
                        && content.replace(" ", "") != "") {
                        content = content.substr_bytes(1, content.size - 2);
                    }
                    var code = Node(NodeKind.Code);
                    code.literal = content;
                    _append(code);
                    _position = run_end;
                    return true;
                }
                search = run_end;
            }
        }
        _append_text(_subject.substr_bytes(start, length));
        return true;
    }

    # Reads a run of `c` (`*`, `_` or `~`) as text, and pushes it on the
    # delimiter stack with whether it can open or close emphasis.
    _parse_delimiters(c: u8): bool {
        var start = _position;
        while (_peek() == c) {
            _position += 1;
        }
        var count = _position - start;
        var piece = _append_text(_subject.substr_bytes(start, count));
        if (c == '~' && count > 2) {
            return true;
        }
        var before = _code_point_before(_subject, start);
        var after = _code_point_at(_subject, _position);
        var before_space = _is_unicode_whitespace(before);
        var after_space = _is_unicode_whitespace(after);
        var before_punctuation = _is_unicode_punctuation(before);
        var after_punctuation = _is_unicode_punctuation(after);
        var left = !after_space && (!after_punctuation || before_space || before_punctuation);
        var right = !before_space && (!before_punctuation || after_space || after_punctuation);
        var delimiter = _Delimiter();
        delimiter.character = c;
        delimiter.count = count;
        delimiter.original_count = count;
        delimiter.piece = piece;
        if (c == '_') {
            delimiter.can_open = left && (!right || before_punctuation);
            delimiter.can_close = right && (!left || after_punctuation);
        } else {
            delimiter.can_open = left;
            delimiter.can_close = right;
        }
        delimiter.previous = _delimiters;
        if (_delimiters !== __null) {
            _delimiters.next = delimiter;
        }
        _delimiters = delimiter;
        return true;
    }

    _remove_delimiter(delimiter: _Delimiter) {
        if (delimiter.previous !== __null) {
            delimiter.previous.next = delimiter.next;
        }
        if (delimiter.next === __null) {
            _delimiters = delimiter.previous;
        } else {
            delimiter.next.previous = delimiter.previous;
        }
        delimiter.previous = __null;
        delimiter.next = __null;
    }

    # Matches the emphasis delimiters above `bottom` with each other,
    # turning each matched pair and what is between them into an
    # `Emphasis`, `Strong` or `Strikethrough`, then removes them all.
    _process_emphasis(bottom: _Delimiter) {
        # For each kind of closer, the lowest delimiter worth searching
        # for its opener: for `_` and `*`, by whether the closer can open
        # and its length modulo 3, and for `~`, by its length.
        var openers_bottom = Array<_Delimiter>();
        for (var index in 0..15) {
            openers_bottom.append(bottom);
        }
        var closer = _delimiters;
        while (closer !== __null && closer.previous !== bottom) {
            closer = closer.previous;
        }
        while (closer !== __null) {
            if (!closer.can_close) {
                closer = closer.next;
                continue;
            }
            var c = closer.character;
            var bottom_index = c == '~' ?
                12 + closer.count :
                (c == '*' ? 6 : 0) + (closer.can_open ? 3 : 0) + closer.original_count % 3;
            var opener = closer.previous;
            var found = false;
            while (opener !== __null && opener !== bottom && opener !== openers_bottom[bottom_index]) {
                if (opener.character == c && opener.can_open) {
                    if (c == '~') {
                        found = opener.count == closer.count;
                    } else {
                        var odd_match = (closer.can_open || opener.can_close)
                            && closer.original_count % 3 != 0
                            && (opener.original_count + closer.original_count) % 3 == 0;
                        found = !odd_match;
                    }
                    if (found) {
                        break;
                    }
                }
                opener = opener.previous;
            }
            if (found && _height_between(opener.piece, closer.piece) >= _MAX_DEPTH) {
                found = false;
            }
            if (!found) {
                openers_bottom[bottom_index] = closer.previous;
                var next = closer.next;
                if (!closer.can_open) {
                    _remove_delimiter(closer);
                }
                closer = next;
                continue;
            }
            var used: ulong = c == '~' ? closer.count : (closer.count >= 2 && opener.count >= 2 ? 2 : 1);
            opener.count -= used;
            closer.count -= used;
            var opener_text = opener.piece.node.literal;
            opener.piece.node.literal = opener_text.substr_bytes(0, opener_text.size - used);
            var closer_text = closer.piece.node.literal;
            closer.piece.node.literal = closer_text.substr_bytes(0, closer_text.size - used);
            var node = Node(c == '~' ? NodeKind.Strikethrough : used == 1 ? NodeKind.Emphasis : NodeKind.Strong);
            var height = _height_between(opener.piece, closer.piece) + 1;
            _move_after(opener.piece, closer.piece, node);
            _insert_after(opener.piece, node, height);
            # The delimiters between the two are text now.
            var between = opener.next;
            while (between !== closer) {
                var next = between.next;
                between.previous = __null;
                between.next = __null;
                between = next;
            }
            opener.next = closer;
            closer.previous = opener;
            if (opener.count == 0) {
                _unlink(opener.piece);
                _remove_delimiter(opener);
            }
            if (closer.count == 0) {
                _unlink(closer.piece);
                var next = closer.next;
                _remove_delimiter(closer);
                closer = next;
            }
        }
        while (_delimiters !== __null && _delimiters !== bottom) {
            _remove_delimiter(_delimiters);
        }
    }

    _insert_after(piece: _Piece, node: Node, height: int) {
        var added = _Piece(node, height);
        added.previous = piece;
        added.next = piece.next;
        if (piece.next === __null) {
            _last = added;
        } else {
            piece.next.previous = added;
        }
        piece.next = added;
    }

    _add_bracket(piece: _Piece, index: ulong, image: bool) {
        if (_brackets !== __null) {
            _brackets.bracket_after = true;
        }
        var bracket = _Bracket();
        bracket.piece = piece;
        bracket.previous = _brackets;
        bracket.previous_delimiter = _delimiters;
        bracket.index = index;
        bracket.image = image;
        bracket.active = true;
        _brackets = bracket;
    }

    _parse_close_bracket(): bool {
        _position += 1;
        var start = _position;
        var opener = _brackets;
        if (opener === __null) {
            _append_text("]");
            return true;
        }
        if (!opener.active) {
            _append_text("]");
            _brackets = opener.previous;
            return true;
        }
        var matched = false;
        var destination = "";
        var title = "";
        if (_peek() == '(') {
            _position += 1;
            _skip_spaces_and_newline();
            var parsed = _parse_link_destination();
            if (parsed.is_value()) {
                destination = parsed.value();
                var before_title = _position;
                _skip_spaces_and_newline();
                if (_position != before_title) {
                    var parsed_title = _parse_link_title();
                    if (parsed_title.is_value()) {
                        title = parsed_title.value();
                    }
                }
                _skip_spaces_and_newline();
                if (_peek() == ')') {
                    _position += 1;
                    matched = true;
                }
            }
            if (!matched) {
                _position = start;
            }
        }
        if (!matched) {
            var before_label = _position;
            var length = _parse_link_label();
            var label = "";
            if (length > 2) {
                label = _subject.substr_bytes(before_label, length);
            } else if (!opener.bracket_after) {
                label = _subject.substr_bytes(opener.index, start - opener.index);
            }
            if (length == 0) {
                _position = start;
            }
            if (label != "") {
                var reference = _references.try_get(_normalize_label(label));
                if (reference.is_value()) {
                    destination = reference.value().destination;
                    title = reference.value().title;
                    matched = true;
                }
            }
        }
        var too_deep = matched && _height_between(opener.piece, __null) >= _MAX_DEPTH;
        if (too_deep) {
            # Every earlier bracket holds this one, so none can match.
            var earlier = opener.previous;
            while (earlier !== __null) {
                earlier.active = false;
                earlier = earlier.previous;
            }
        }
        if (!matched || too_deep) {
            _brackets = opener.previous;
            _position = start;
            _append_text("]");
            return true;
        }
        _process_emphasis(opener.previous_delimiter);
        var node = Node(opener.image ? NodeKind.Image : NodeKind.Link);
        node.destination = destination;
        node.title = title;
        var height = _height_between(opener.piece, __null) + 1;
        _move_after(opener.piece, __null, node);
        _unlink(opener.piece);
        _brackets = opener.previous;
        var piece = _append(node);
        piece.height = height;
        if (!opener.image) {
            # No links in links: the `[`s before this one cannot open links.
            var earlier = _brackets;
            while (earlier !== __null) {
                if (!earlier.image) {
                    earlier.active = false;
                }
                earlier = earlier.previous;
            }
        }
        return true;
    }

    # Reads a link label (`[...]`) at the position, and returns its length
    # with the brackets, or 0 (staying put) when there is none.
    _parse_link_label(): ulong {
        if (_peek() != '[') {
            return 0;
        }
        var index = _position + 1;
        var characters = 0;
        while (index < _subject.size && characters <= 999) {
            var c = _subject.byte_at(index);
            if (c == '\\' && index + 1 < _subject.size) {
                index += 2;
                characters += 2;
                continue;
            }
            if (c == '[') {
                return 0;
            }
            if (c == ']') {
                var length = index + 1 - _position;
                _position = index + 1;
                return length;
            }
            if ((c & 0xC0) != 0x80) {
                characters += 1;
            }
            index += 1;
        }
        return 0;
    }

    # Reads a link destination, `<...>` or a run without spaces whose
    # parentheses balance, and returns it unescaped and percent-encoded.
    _parse_link_destination(): String? {
        var start = _position;
        if (_peek() == '<') {
            var index = _position + 1;
            while (index < _subject.size) {
                var c = _subject.byte_at(index);
                if (c == '>') {
                    _position = index + 1;
                    return Optional<String>.Value(
                        _normalize_url(_unescape(_subject.substr_bytes(start + 1, index - start - 1)))
                    );
                }
                if (c == '<' || c == '\n') {
                    break;
                }
                index += c == '\\' && index + 1 < _subject.size ? 2 : 1;
            }
            return Optional<String>.Empty;
        }
        var parentheses = 0;
        while (_position < _subject.size) {
            var c = _subject.byte_at(_position);
            if (c == '\\' && _position + 1 < _subject.size && _is_ascii_punctuation(_subject.byte_at(_position + 1))) {
                _position += 2;
            } else if (c == '(') {
                # Deeper nesting is not a destination, as in cmark, so text
                # full of `(` is not scanned to its end again and again.
                if (parentheses == 32) {
                    break;
                }
                _position += 1;
                parentheses += 1;
            } else if (c == ')') {
                if (parentheses < 1) {
                    break;
                }
                _position += 1;
                parentheses -= 1;
            } else if (c <= ' ' || c == 0x7F) {
                break;
            } else {
                _position += 1;
            }
        }
        if ((_position == start && _peek() != ')') || parentheses != 0) {
            _position = start;
            return Optional<String>.Empty;
        }
        return Optional<String>.Value(_normalize_url(_unescape(_subject.substr_bytes(start, _position - start))));
    }

    # Reads a link title in `"..."`, `'...'` or `(...)`, and returns it
    # unescaped.
    _parse_link_title(): String? {
        var open = _peek();
        var close = open;
        if (open == '(') {
            close = ')';
        }
        if (open != '"' && open != '\'' && open != '(') {
            return Optional<String>.Empty;
        }
        var index = _position + 1;
        while (index < _subject.size) {
            var c = _subject.byte_at(index);
            if (c == '\\' && index + 1 < _subject.size) {
                index += 2;
                continue;
            }
            if (c == close) {
                var title = _subject.substr_bytes(_position + 1, index - _position - 1);
                _position = index + 1;
                return Optional<String>.Value(_unescape(title));
            }
            if (open == '(' && c == '(') {
                break;
            }
            index += 1;
        }
        return Optional<String>.Empty;
    }

    # Skips spaces and tabs, and at most one line ending among them.
    _skip_spaces_and_newline() {
        while (_is_space_or_tab(_peek())) {
            _position += 1;
        }
        if (_peek() == '\n') {
            _position += 1;
            while (_is_space_or_tab(_peek())) {
                _position += 1;
            }
        }
    }

    # Whether only spaces and tabs are left on the line; if so, moves past
    # them and the line ending.
    _at_line_end(): bool {
        var index = _position;
        while (index < _subject.size && _is_space_or_tab(_subject.byte_at(index))) {
            index += 1;
        }
        if (index < _subject.size && _subject.byte_at(index) != '\n') {
            return false;
        }
        _position = index < _subject.size ? index + 1 : index;
        return true;
    }

    # Reads an autolink, `<scheme:...>` or `<user@host>`.
    _parse_autolink(): bool {
        var start = _position + 1;
        var index = start;
        while (index < _subject.size
            && (_subject.byte_at(index).is_alphanumeric()
                || _subject.byte_at(index) == '+'
                || _subject.byte_at(index) == '.'
                || _subject.byte_at(index) == '-')) {
            index += 1;
        }
        var scheme = index - start;
        if (scheme >= 2
            && scheme <= 32
            && _subject.byte_at(start).is_alphabetic()
            && index < _subject.size
            && _subject.byte_at(index) == ':') {
            index += 1;
            while (index < _subject.size
                && _subject.byte_at(index) > ' '
                && _subject.byte_at(index) != '<'
                && _subject.byte_at(index) != '>'
                && _subject.byte_at(index) != 0x7F) {
                index += 1;
            }
            if (index < _subject.size && _subject.byte_at(index) == '>') {
                var url = _subject.substr_bytes(start, index - start);
                _add_link(_normalize_url(url), url);
                _position = index + 1;
                return true;
            }
        }
        var email = _email_length(_subject, start);
        if (email > 0 && start + email < _subject.size && _subject.byte_at(start + email) == '>') {
            var address = _subject.substr_bytes(start, email);
            _add_link(_normalize_url("mailto:" + address), address);
            _position = start + email + 1;
            return true;
        }
        return false;
    }

    _add_link(destination: String, text: String) {
        var link = Node(NodeKind.Link);
        link.destination = destination;
        var child = Node(NodeKind.Text);
        child.literal = text;
        link.children.append(child);
        _append(link);
    }

    _parse_html_tag(): bool {
        var length = _scan_html_tag();
        if (length == 0) {
            return false;
        }
        var html = Node(NodeKind.HtmlInline);
        html.literal = _subject.substr_bytes(_position, length);
        _append(html);
        _position += length;
        return true;
    }

    # The length of the raw HTML at the position (a tag, comment,
    # processing instruction, declaration or CDATA section), or 0.
    _scan_html_tag(): ulong {
        var s = _subject;
        var start = _position;
        if (start + 1 >= s.size) {
            return 0;
        }
        var c = s.byte_at(start + 1);
        if (c == '!') {
            if (_starts_at(s, start, "<!--")) {
                if (_starts_at(s, start, "<!-->")) {
                    return 5;
                }
                if (_starts_at(s, start, "<!--->")) {
                    return 6;
                }
                return _scan_to(start + 4, "-->", start);
            }
            if (_starts_at(s, start, "<![CDATA[")) {
                return _scan_to(start + 9, "]]>", start);
            }
            if (start + 2 < s.size && s.byte_at(start + 2).is_alphabetic()) {
                return _scan_to(start + 2, ">", start);
            }
            return 0;
        }
        if (c == '?') {
            return _scan_to(start + 2, "?>", start);
        }
        return _scan_open_or_closing_tag(s, start);
    }

    # The length from `start` to the end of the first `closing` at or
    # after `from`, or 0 when there is none.
    _scan_to(from: ulong, closing: String, start: ulong): ulong {
        if (_missing_closings.contains(closing)) {
            return 0;
        }
        var found = _subject.find(closing, from);
        if (found < 0) {
            _missing_closings.insert(closing);
            return 0;
        }
        return (found as ulong) + closing.size - start;
    }
}

# The length of the open tag (`<a href="x">`) or closing tag (`</a>`) at
# byte `start` of `s`, or 0 when there is none.
_scan_open_or_closing_tag(s: String, start: ulong): ulong {
    var index = start + 1;
    var closing = index < s.size && s.byte_at(index) == '/';
    if (closing) {
        index += 1;
    }
    if (index >= s.size || !s.byte_at(index).is_alphabetic()) {
        return 0;
    }
    while (index < s.size && (s.byte_at(index).is_alphanumeric() || s.byte_at(index) == '-')) {
        index += 1;
    }
    if (closing) {
        index = _skip_html_space(s, index);
        return index < s.size && s.byte_at(index) == '>' ? index + 1 - start : 0;
    }
    while (true) {
        var after_space = _skip_html_space(s, index);
        if (after_space == index || after_space >= s.size || !_is_attribute_name_start(s.byte_at(after_space))) {
            index = after_space;
            break;
        }
        index = after_space + 1;
        while (index < s.size
            && (_is_attribute_name_start(s.byte_at(index))
                || s.byte_at(index).is_digit()
                || s.byte_at(index) == '.'
                || s.byte_at(index) == '-')) {
            index += 1;
        }
        var before_value = index;
        index = _skip_html_space(s, index);
        if (index < s.size && s.byte_at(index) == '=') {
            index = _skip_html_space(s, index + 1);
            var value_end = _attribute_value_end(s, index);
            if (value_end == 0) {
                return 0;
            }
            index = value_end;
        } else {
            index = before_value;
        }
    }
    if (index < s.size && s.byte_at(index) == '/') {
        index += 1;
    }
    return index < s.size && s.byte_at(index) == '>' ? index + 1 - start : 0;
}

private _is_attribute_name_start(c: u8): bool {
    return c.is_alphabetic() || c == '_' || c == ':';
}

# Skips spaces, tabs and line endings.
private _skip_html_space(s: String, from: ulong): ulong {
    var index = from;
    while (index < s.size && _is_ascii_whitespace(s.byte_at(index))) {
        index += 1;
    }
    return index;
}

# The end of the attribute value at `start`: quoted, or a run without
# spaces, quotes, `=`, `<`, `>` or backticks; 0 when there is none.
private _attribute_value_end(s: String, start: ulong): ulong {
    if (start >= s.size) {
        return 0;
    }
    var c = s.byte_at(start);
    if (c == '"' || c == '\'') {
        var close = s.find(c == '"' ? "\"" : "'", start + 1);
        return close < 0 ? 0 : (close as ulong) + 1;
    }
    var index = start;
    while (index < s.size) {
        var d = s.byte_at(index);
        if (d <= ' ' || d == '"' || d == '\'' || d == '=' || d == '<' || d == '>' || d == '`') {
            break;
        }
        index += 1;
    }
    return index == start ? 0 : index;
}

# The length of the email address at byte `start` of `s`, as autolinks
# allow it, or 0.
private _email_length(s: String, start: ulong): ulong {
    var index = start;
    while (index < s.size) {
        var c = s.byte_at(index);
        if (c >= 0x80 || !(c.is_alphanumeric() || ".!#$%&'*+/=?^_`{|}~-".contains(s.substr_bytes(index, 1)))) {
            break;
        }
        index += 1;
    }
    if (index == start || index >= s.size || s.byte_at(index) != '@') {
        return 0;
    }
    index += 1;
    while (true) {
        var label_start = index;
        while (index < s.size
            && index - label_start < 63
            && (s.byte_at(index).is_alphanumeric() || s.byte_at(index) == '-')) {
            index += 1;
        }
        if (index == label_start
            || !s.byte_at(label_start).is_alphanumeric()
            || !s.byte_at(index - 1).is_alphanumeric()) {
            return 0;
        }
        if (index + 1 < s.size && s.byte_at(index) == '.' && s.byte_at(index + 1).is_alphanumeric()) {
            index += 1;
            continue;
        }
        return index - start;
    }
    return 0;
}

# The nodes of the list that starts at `first`, with the list's links
# undone.
private _take_pieces(first: _Piece): Array<Node> {
    var nodes = Array<Node>();
    var piece = first;
    while (piece !== __null) {
        nodes.append(piece.node);
        var next = piece.next;
        piece.previous = __null;
        piece.next = __null;
        piece = next;
    }
    return nodes;
}

# `nodes` with adjacent text merged and empty text dropped.
private _finish(nodes: Array<Node>): Array<Node> {
    var merged = Array<Node>();
    for (var node in nodes) {
        if (node.kind == NodeKind.Text) {
            if (node.literal.is_empty) {
                continue;
            }
            if (!merged.is_empty && merged.last().kind == NodeKind.Text) {
                var text = Node(NodeKind.Text);
                text.literal = merged.last().literal + node.literal;
                merged[merged.count - 1] = text;
                continue;
            }
        }
        merged.append(node);
    }
    return merged;
}
