## Character classes and text transforms that both parsers and the HTML
## renderer use: escaping, entities, label normalization and URL encoding.

import text;
import "tables";

# Whether `c`, a byte or -1 for the end, is a space or a tab.
_is_space_or_tab(c: int): bool {
    return c == ' ' || c == '\t';
}

# Whether `c` is a line ending or other ASCII whitespace the spec counts.
_is_ascii_whitespace(c: int): bool {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0x0B || c == 0x0C;
}

# Whether `c` is ASCII punctuation: the characters a backslash escapes.
_is_ascii_punctuation(c: int): bool {
    return (c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') || (c >= '{' && c <= '~');
}

# Whether the code point is Unicode whitespace as the spec defines it: the
# Zs category, tab, line feed, form feed or carriage return.
_is_unicode_whitespace(point: uint): bool {
    if (point < 0x80) {
        return point == ' ' || point == '\t' || point == '\n' || point == 0x0C || point == '\r';
    }
    return point == 0xA0
        || point == 0x1680
        || (point >= 0x2000 && point <= 0x200A)
        || point == 0x202F
        || point == 0x205F
        || point == 0x3000;
}

# Whether the code point is Unicode punctuation as the spec defines it: the
# P and S categories.
_is_unicode_punctuation(point: uint): bool {
    if (point < 0x80) {
        return _is_ascii_punctuation(point as int);
    }
    var position: ulong = 1;
    while (position < _PUNCTUATION.size) {
        var dash = _PUNCTUATION.find("-", position) as ulong;
        var comma = _PUNCTUATION.find(",", dash) as ulong;
        var first = _hex(_PUNCTUATION, position, dash);
        if (point < first) {
            return false;
        }
        if (point <= _hex(_PUNCTUATION, dash + 1, comma)) {
            return true;
        }
        position = comma + 1;
    }
    return false;
}

# The value of the hexadecimal digits of `s` from `start` up to `end`.
_hex(s: String, start: ulong, end: ulong): uint {
    var value: uint = 0;
    for (var index in start..end) {
        value = value * 16 + s.byte_at(index).digit_value(16).value() as uint;
    }
    return value;
}

# The code point that ends just before byte `index` of `s`, or a line
# feed at the start.
_code_point_before(s: String, index: ulong): uint {
    if (index == 0) {
        return '\n';
    }
    var start = index - 1;
    while (start > 0 && index - start < 4 && (s.byte_at(start) & 0xC0) == 0x80) {
        start -= 1;
    }
    var (point, _) = text.Utf8.code_point_at(s, start);
    return point;
}

# The code point that starts at byte `index` of `s`, or a line feed at the
# end.
_code_point_at(s: String, index: ulong): uint {
    if (index >= s.size) {
        return '\n';
    }
    var (point, _) = text.Utf8.code_point_at(s, index);
    return point;
}

# Whether `s` holds `prefix` at byte `index`.
_starts_at(s: String, index: ulong, prefix: String): bool {
    if (index + prefix.size > s.size) {
        return false;
    }
    for (var offset in 0..prefix.size) {
        if (s.byte_at(index + offset) != prefix.byte_at(offset)) {
            return false;
        }
    }
    return true;
}

# `s` with `&`, `<`, `>` and `"` escaped for HTML text and attributes.
_escape_html(s: String): String {
    var out = StringBuilder();
    var start: ulong = 0;
    for (var index in 0..s.size) {
        var c = s.byte_at(index);
        var replacement = "";
        if (c == '&') {
            replacement = "&amp;";
        } else if (c == '<') {
            replacement = "&lt;";
        } else if (c == '>') {
            replacement = "&gt;";
        } else if (c == '"') {
            replacement = "&quot;";
        } else {
            continue;
        }
        out.append(s.substr_bytes(start, index - start));
        out.append(replacement);
        start = index + 1;
    }
    out.append(s.substr_bytes(start, s.size - start));
    return out.to_string();
}

# The length of the entity or numeric character reference at byte `index`
# of `s` (`&amp;`, `&#35;`, `&#x22;`), and its text; none when there is
# none there, or the name is not an HTML entity.
_entity_at(s: String, index: ulong): (ulong, String)? {
    if (index + 2 >= s.size || s.byte_at(index) != '&') {
        return Optional<(ulong, String)>.Empty;
    }
    var position = index + 1;
    if (s.byte_at(position) == '#') {
        position += 1;
        var hexadecimal = position < s.size && (s.byte_at(position) == 'x' || s.byte_at(position) == 'X');
        if (hexadecimal) {
            position += 1;
        }
        var digits_start = position;
        while (position < s.size
            && (hexadecimal ? s.byte_at(position).is_hex_digit() : s.byte_at(position).is_digit())) {
            position += 1;
        }
        var digits = position - digits_start;
        if (digits == 0 || digits > (hexadecimal ? 6 : 7) || position >= s.size || s.byte_at(position) != ';') {
            return Optional<(ulong, String)>.Empty;
        }
        var point = uint.parse(s.substr_bytes(digits_start, digits), hexadecimal ? 16 : 10).value();
        if (point == 0 || point > 0x10FFFF || (point >= 0xD800 && point <= 0xDFFF)) {
            point = 0xFFFD;
        }
        return Optional<(ulong, String)>.Value((position + 1 - index, _from_code_points([point])));
    }
    var name_start = position;
    while (position < s.size && position - name_start < 32 && s.byte_at(position).is_alphanumeric()) {
        position += 1;
    }
    if (position == name_start || position >= s.size || s.byte_at(position) != ';') {
        return Optional<(ulong, String)>.Empty;
    }
    var points = _look_up(_ENTITIES, s.substr_bytes(name_start, position - name_start), false);
    if (points.is_empty()) {
        return Optional<(ulong, String)>.Empty;
    }
    return Optional<(ulong, String)>.Value((position + 1 - index, _from_code_points(points.value())));
}

# The code points a table of `tables.pep` (sorted `\nkey:code points`
# records) holds for `key`, a name or, when `numeric`, a code point in
# hexadecimal. A binary search, since the tables are large.
_look_up(table: String, key: String, numeric: bool): Array<uint>? {
    var low: ulong = 1;
    var high = table.size - 1;
    while (low < high) {
        var record = (low + high) / 2;
        while (table.byte_at(record - 1) != '\n') {
            record -= 1;
        }
        var colon = table.find(":", record) as ulong;
        var end = table.find("\n", colon) as ulong;
        # Hexadecimal keys order by length first.
        var order = numeric && key.size != colon - record ?
            (key.size < colon - record ? -1 : 1) :
            key.compare(table.substr_bytes(record, colon - record));
        if (order == 0) {
            var points = Array<uint>();
            for (var hex in table.substr_bytes(colon + 1, end - colon - 1).split(",")) {
                points.append(uint.parse(hex, 16).value());
            }
            return Optional<Array<uint>>.Value(points);
        }
        if (order < 0) {
            high = record;
        } else {
            low = end + 1;
        }
    }
    return Optional<Array<uint>>.Empty;
}

# The UTF-8 text of `points`.
_from_code_points(points: Array<uint>): String {
    var bytes = Array<u8>();
    for (var point in points) {
        text.Utf8.append_code_point(bytes, point);
    }
    return text.Utf8.decode(bytes).value();
}

# `s` with its backslash escapes and entity references resolved.
_unescape(s: String): String {
    if (s.find("\\") < 0 && s.find("&") < 0) {
        return s;
    }
    var out = StringBuilder();
    var start: ulong = 0;
    var index: ulong = 0;
    while (index < s.size) {
        var c = s.byte_at(index);
        if (c == '\\' && index + 1 < s.size && _is_ascii_punctuation(s.byte_at(index + 1))) {
            out.append(s.substr_bytes(start, index - start));
            start = index + 1;
            index += 2;
            continue;
        }
        if (c == '&') {
            var entity = _entity_at(s, index);
            if (entity.is_value()) {
                var (length, decoded) = entity.value();
                out.append(s.substr_bytes(start, index - start));
                out.append(decoded);
                index += length;
                start = index;
                continue;
            }
        }
        index += 1;
    }
    out.append(s.substr_bytes(start, s.size - start));
    return out.to_string();
}

# A link label (with its brackets) as references are matched: whitespace
# collapsed to single spaces, trimmed, and Unicode case-folded.
_normalize_label(label: String): String {
    var out = StringBuilder();
    var space = false;
    var index: ulong = 1;
    var end = label.size - 1;
    while (index < end) {
        var c = label.byte_at(index);
        if (_is_ascii_whitespace(c)) {
            space = true;
            index += 1;
            continue;
        }
        if (space && !out.is_empty) {
            out.append(" ");
        }
        space = false;
        if (c < 0x80) {
            out.append(label.substr_bytes(index, 1).lower());
            index += 1;
            continue;
        }
        var (point, run) = text.Utf8.code_point_at(label, index);
        var folded = _look_up(_CASE_FOLDING, $"{point:X}", true);
        out.append(folded.is_value() ? _from_code_points(folded.value()) : label.substr_bytes(index, run));
        index += run;
    }
    return out.to_string();
}

# `url` percent-encoded as commonmark.js does: each byte outside the
# characters URLs allow becomes `%XX`, and a `%` already followed by two
# hexadecimal digits is kept.
_normalize_url(url: String): String {
    var out = StringBuilder();
    for (var index in 0..url.size) {
        var c = url.byte_at(index);
        if (c == '%'
            && index + 2 < url.size
            && url.byte_at(index + 1).is_hex_digit()
            && url.byte_at(index + 2).is_hex_digit()) {
            out.append("%");
        } else if (c.is_alphanumeric() || (c < 0x80 && ";/?:@&=+$,-_.!~*'()#".contains(url.substr_bytes(index, 1)))) {
            out.append(url.substr_bytes(index, 1));
        } else {
            out.append($"%{c:02X}");
        }
    }
    return out.to_string();
}
