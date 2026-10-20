"""Writes tests/testdata/gfm-extensions.json: the examples of the GFM spec
that test its extensions, in the format of the CommonMark spec.json.

Usage: python scripts/gfm_examples.py spec.txt tests/testdata/gfm-extensions.json

spec.txt is cmark-gfm's test/spec.txt
(https://github.com/github/cmark-gfm/blob/master/test/spec.txt). An
extension's examples are those whose fence names it (`example table`).
"""
import json
import re
import sys

FENCE = '`' * 32

lines = open(sys.argv[1], encoding='utf-8').read().split('\n')
examples = []
section = ''
number = 0
index = 0
while index < len(lines):
    line = lines[index]
    heading = re.match(r'#+ (.*)', line)
    if heading:
        section = heading.group(1)
    if line.startswith(FENCE + ' example'):
        number += 1
        extension = line[len(FENCE + ' example'):].strip()
        start = index + 1
        index += 1
        markdown = []
        while lines[index] != '.':
            markdown.append(lines[index])
            index += 1
        index += 1
        html = []
        while not lines[index].startswith(FENCE):
            html.append(lines[index])
            index += 1
        if extension:
            # The spec shows each tab as a right arrow.
            text = lambda part: ''.join(l + '\n' for l in part).replace('→', '\t')
            examples.append({
                'markdown': text(markdown),
                'html': text(html),
                'example': number,
                'start_line': start,
                'end_line': index + 1,
                'section': section,
                'extension': extension,
            })
    index += 1

with open(sys.argv[2], 'w', encoding='utf-8', newline='\n') as out:
    json.dump(examples, out, indent=2, ensure_ascii=False)
