## GFM's extended autolinks: `www.` addresses, `http://`, `https://` and
## `ftp://` URLs, and email addresses in text become links without `<>`.

import "characters";
import "node";

# `nodes` with the extended autolinks in their text made links, searching
# every inline but links and images.
_autolinked(nodes: Array<Node>): Array<Node> {
    var top = Node(NodeKind.Document);
    top.children = nodes;
    # A stack rather than recursion, for deeply nested emphasis.
    var pending = [top];
    while (!pending.is_empty) {
        var parent = pending.pop();
        var children = Array<Node>();
        for (var node in parent.children) {
            if (node.kind == NodeKind.Text) {
                _split_autolinks(node.literal, children);
                continue;
            }
            if (node.kind != NodeKind.Link && node.kind != NodeKind.Image && !node.children.is_empty) {
                pending.append(node);
            }
            children.append(node);
        }
        parent.children = children;
    }
    return top.children;
}

# Appends `text` to `out` as text and links.
private _split_autolinks(text: String, out: Array<Node>) {
    var cut: ulong = 0;
    var index: ulong = 0;
    while (index < text.size) {
        var c = text.byte_at(index);
        var start = index;
        var end: ulong = 0;
        var prefix = "";
        if (c == 'w' && _may_start_www(text, index)) {
            end = _www_end(text, index);
            prefix = "http://";
        } else if (c == ':' && _starts_at(text, index, "://")) {
            var scheme_start = index;
            while (scheme_start > cut && text.byte_at(scheme_start - 1).is_alphabetic()) {
                scheme_start -= 1;
            }
            var scheme = text.substr_bytes(scheme_start, index - scheme_start).lower();
            if (scheme == "http" || scheme == "https" || scheme == "ftp") {
                var domain = _domain_length(text, index + 3, true);
                if (domain > 0) {
                    start = scheme_start;
                    end = _trim_link_end(text, start, _path_end(text, index + 3 + domain));
                }
            }
        } else if (c == '@') {
            var local_start = index;
            while (local_start > cut && _is_email_local(text.byte_at(local_start - 1))) {
                local_start -= 1;
            }
            if (local_start < index) {
                start = local_start;
                end = _email_end(text, index);
                prefix = "mailto:";
            }
        }
        if (end <= start) {
            index += 1;
            continue;
        }
        if (start > cut) {
            out.append(_text_node(text.substr_bytes(cut, start - cut)));
        }
        var shown = text.substr_bytes(start, end - start);
        var link = Node(NodeKind.Link);
        link.destination = _normalize_url(prefix + shown);
        link.children.append(_text_node(shown));
        out.append(link);
        cut = end;
        index = end;
    }
    if (cut < text.size) {
        out.append(_text_node(text.substr_bytes(cut, text.size - cut)));
    }
}

private _text_node(text: String): Node {
    var node = Node(NodeKind.Text);
    node.literal = text;
    return node;
}

# Whether a `www.` link may start at `index`: at the start, or after a
# space or one of `*`, `_`, `~` and `(`.
private _may_start_www(text: String, index: ulong): bool {
    if (!_starts_at(text, index, "www.")) {
        return false;
    }
    if (index == 0) {
        return true;
    }
    var before = text.byte_at(index - 1);
    return _is_ascii_whitespace(before) || before == '*' || before == '_' || before == '~' || before == '(';
}

private _www_end(text: String, index: ulong): ulong {
    var domain = _domain_length(text, index, false);
    if (domain == 0) {
        return 0;
    }
    return _trim_link_end(text, index, _path_end(text, index + domain));
}

# The length of the valid domain at `start`: letters, digits, `-`, `_` and
# non-ASCII characters in segments split by `.`, with no `_` in the last
# two segments, and unless `allow_short`, at least one `.`.
private _domain_length(text: String, start: ulong, allow_short: bool): ulong {
    var index = start;
    var dots = 0;
    var underscore_last = false;
    var underscore_before = false;
    while (index < text.size) {
        var c = text.byte_at(index);
        if (c == '.') {
            underscore_before = underscore_last;
            underscore_last = false;
            dots += 1;
        } else if (c == '_') {
            underscore_last = true;
        } else if (!(c.is_alphanumeric() || c == '-' || c >= 0x80)) {
            break;
        }
        index += 1;
    }
    if (index == start || underscore_last || underscore_before || (!allow_short && dots == 0)) {
        return 0;
    }
    return index - start;
}

# The end of a link's path: the first space or `<` from `index`.
private _path_end(text: String, index: ulong): ulong {
    var end = index;
    while (end < text.size && !_is_ascii_whitespace(text.byte_at(end)) && text.byte_at(end) != '<') {
        end += 1;
    }
    return end;
}

# Moves the end of the link that runs from `start` to `end` back over
# trailing punctuation, an entity reference such as `&amp;`, and the `)`s
# that do not close a `(` in the link.
private _trim_link_end(text: String, start: ulong, end: ulong): ulong {
    var link_end = end;
    while (link_end > start) {
        var c = text.byte_at(link_end - 1);
        if (c == '?' || c == '!' || c == '.' || c == ',' || c == ':' || c == '*' || c == '_' || c == '~') {
            link_end -= 1;
        } else if (c == ';') {
            var name_start = link_end - 1;
            while (name_start > start && text.byte_at(name_start - 1).is_alphanumeric()) {
                name_start -= 1;
            }
            if (name_start < link_end - 1 && name_start > start && text.byte_at(name_start - 1) == '&') {
                link_end = name_start - 1;
            } else {
                link_end -= 1;
            }
        } else if (c == ')') {
            var opening = 0;
            var closing = 0;
            for (var index in start..link_end) {
                if (text.byte_at(index) == '(') {
                    opening += 1;
                } else if (text.byte_at(index) == ')') {
                    closing += 1;
                }
            }
            if (closing <= opening) {
                break;
            }
            link_end -= 1;
        } else {
            break;
        }
    }
    return link_end;
}

private _is_email_local(c: u8): bool {
    return c.is_alphanumeric() || c == '.' || c == '+' || c == '-' || c == '_';
}

# The end of the email address whose `@` is at `at`, or 0 when what
# follows is not a domain: segments of letters, digits, `-` and `_` split
# by `.`, at least two, the last ending in a letter.
private _email_end(text: String, at: ulong): ulong {
    var index = at + 1;
    var dots = 0;
    while (index < text.size) {
        var c = text.byte_at(index);
        if (c == '.' && index + 1 < text.size && text.byte_at(index + 1).is_alphanumeric()) {
            dots += 1;
        } else if (!(c.is_alphanumeric() || c == '-' || c == '_')) {
            break;
        }
        index += 1;
    }
    if (dots == 0 || index == at + 1 || !text.byte_at(index - 1).is_alphabetic()) {
        return 0;
    }
    return index;
}
