## The tree `parse` builds: a `Node` for each block and inline element,
## and `Event`, one step of a walk over it.

## What a `Node` is.
export enum NodeKind {
    ## The root; its children are the top-level blocks.
    Document,
    ## A block quote (`> ...`); its children are blocks.
    BlockQuote,
    ## A bullet or ordered list; its children are `Item`s.
    List,
    ## A list item; its children are blocks.
    Item,
    ## A fenced or indented code block; `literal` is its text and `info`
    ## its info string.
    CodeBlock,
    ## A block of raw HTML; `literal` is its text.
    HtmlBlock,
    ## A paragraph; its children are inlines.
    Paragraph,
    ## An ATX (`# ...`) or setext heading of `level` 1 to 6; its children
    ## are inlines.
    Heading,
    ## A thematic break (`***`).
    ThematicBreak,
    ## A GFM table; its children are `TableRow`s, the header row first.
    Table,
    ## A row of a table; `header` says whether it is the header row, and
    ## its children are `TableCell`s.
    TableRow,
    ## A cell of a table row, aligned as `alignment` says; its children
    ## are inlines.
    TableCell,
    ## Text; `literal` is the text, with escapes and entities resolved.
    Text,
    ## A line ending inside a paragraph that is not a hard break.
    SoftBreak,
    ## A hard line break (two spaces or `\` before a line ending).
    LineBreak,
    ## A code span; `literal` is its text.
    Code,
    ## Raw inline HTML (a tag, comment, ...); `literal` is its text.
    HtmlInline,
    ## Emphasis (`*a*`); its children are inlines.
    Emphasis,
    ## Strong emphasis (`**a**`); its children are inlines.
    Strong,
    ## GFM strikethrough (`~~a~~`); its children are inlines.
    Strikethrough,
    ## A link to `destination`, with `title`; its children are the link
    ## text.
    Link,
    ## An image of `destination`, with `title`; its children are the
    ## description, which the HTML renders as the `alt` text.
    Image,
}

## How a table cell's text is aligned.
export enum Alignment {
    ## No alignment was given (`---`).
    None,
    ## Aligned left (`:--`).
    Left,
    ## Centered (`:-:`).
    Center,
    ## Aligned right (`--:`).
    Right,
}

## A block or inline element of a parsed document.
##
## One struct holds every kind; `kind` says which, and only the fields that
## kind describes are set (the others keep their defaults). A renderer of
## its own walks `children` recursively or uses `events()`.
##
## @example
##     import markdown;
##
##     main(): int {
##         var doc = markdown.parse("# Hi *there*\n");
##         var heading = doc.children[0];
##         assert(heading.kind == markdown.NodeKind.Heading && heading.level == 1, "a level 1 heading");
##         assert(heading.children[1].kind == markdown.NodeKind.Emphasis, "then emphasis");
##         return 0;
##     }
export struct Node {
    ## What this node is.
    var kind: NodeKind;
    ## The child nodes, in order.
    var children: Array<Node>;
    ## The text of a `Text`, `Code`, `CodeBlock`, `HtmlBlock` or
    ## `HtmlInline`.
    var literal: String;
    ## The info string of a fenced `CodeBlock` (`rust` in ```` ```rust ````),
    ## with escapes and entities resolved; empty for an indented one.
    var info: String;
    ## The URL of a `Link` or `Image`, percent-encoded.
    var destination: String;
    ## The title of a `Link` or `Image`; empty when it has none.
    var title: String;
    ## The level of a `Heading`, 1 to 6.
    var level: int;
    ## Whether a `List` is ordered (`1.`) rather than bulleted (`-`).
    var ordered: bool;
    ## The number of an ordered `List`'s first item.
    var start: int;
    ## Whether a `List` is tight: no blank line separates its items or
    ## their blocks, so its paragraphs render without `<p>`.
    var tight: bool;
    ## Whether an `Item` is a GFM task list item (`- [ ] ...`).
    var task: bool;
    ## Whether a task list `Item` is checked (`- [x] ...`).
    var checked: bool;
    ## Whether a `TableRow` is the table's header row.
    var header: bool;
    ## The alignment of a `TableCell`.
    var alignment: Alignment;

    ## Makes a node of `kind` with no children.
    ##
    ## @param kind what the node is
    construct(kind: NodeKind) {
        this.kind = kind;
        children = Array<Node>();
        literal = "";
        info = "";
        destination = "";
        title = "";
    }

    ## Lists the steps of a depth-first walk over this node and its
    ## descendants: an entering event for each node, then its children's
    ## events, then a leaving event. A node with no children (a `Text`,
    ## say) has an entering event and a leaving one too.
    ##
    ## @returns the events, the first entering this node
    ## @example
    ##     import markdown;
    ##
    ##     main(): int {
    ##         var words = 0;
    ##         for (var event in markdown.parse("a *b* c\n").events()) {
    ##             if (event.entering && event.node.kind == markdown.NodeKind.Text) {
    ##                 words += 1;
    ##             }
    ##         }
    ##         assert(words == 3, "three text nodes");
    ##         return 0;
    ##     }
    events(): Array<Event> {
        # A stack rather than recursion, so a deeply nested tree cannot
        # overflow the call stack.
        var out = [Event(true, this)];
        var nodes = [this];
        var next = [0 as ulong];
        while (!nodes.is_empty) {
            var node = nodes.last();
            var index = next.last();
            if (index < node.children.count) {
                next[next.count - 1] = index + 1;
                var child = node.children[index];
                out.append(Event(true, child));
                nodes.append(child);
                next.append(0);
            } else {
                nodes.pop();
                next.pop();
                out.append(Event(false, node));
            }
        }
        return out;
    }
}

## One step of a walk over a tree of `Node`s: entering a node, or leaving
## it after its children.
export struct Event {
    ## Whether the walk enters `node` (true) or leaves it (false).
    var entering: bool;
    ## The node entered or left.
    var node: Node;

    ## Makes an event.
    ##
    ## @param entering whether the walk enters `node`
    ## @param node the node entered or left
    construct(entering: bool, node: Node) {
        this.entering = entering;
        this.node = node;
    }
}
