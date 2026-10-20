# The package against the CommonMark 0.31.2 spec's examples, with the GFM
# extensions off, and the GFM spec's extension examples, with them on:
# every example's HTML must match exactly. `tests/run.sh` runs the tests
# from the repository's root.

import io;
import json;
import markdown;

const TESTDATA = "tests/testdata";

# The numbers of the examples in `file` whose HTML differs, each printed
# with what it rendered.
failures(file: String, options: markdown.Options): Array<long> {
    var text = io.File.read_to_string(io.Path(TESTDATA).join(file)).value();
    var failed = Array<long>();
    var examples = json.parse(text).value().as_array().value();
    for (var example in examples) {
        var input = example["markdown"].as_string().value();
        var expected = example["html"].as_string().value();
        var actual = markdown.to_html(input, options);
        if (actual != expected) {
            var number = example["example"].as_int().value();
            failed.append(number);
            print($"{file} example {number} ({example["section"].as_string().value()}):");
            print($"  markdown: {json.JsonValue.String(input).to_string()}");
            print($"  expected: {json.JsonValue.String(expected).to_string()}");
            print($"  actual:   {json.JsonValue.String(actual).to_string()}");
        }
    }
    print($"{file}: {examples.count - failed.count} of {examples.count} examples pass");
    return failed;
}

[Test]
passes_the_commonmark_spec() {
    expect_equal(failures("commonmark-spec.json", markdown.Options(gfm = false)).count, 0);
}

[Test]
passes_the_gfm_extension_examples() {
    expect_equal(failures("gfm-extensions.json", markdown.Options()).count, 0);
}
