#!/usr/bin/env python3
"""Inline example programs into cookbook pages.

A cookbook page never contains typed code. It carries markers:

    <!-- druse:begin examples/02-json-api/main.odin -->
    <!-- druse:end -->

and this script fills the space between them from the real source, which the
build check compiles. Run with --check to fail when a page has drifted.
"""
import re,sys,os

BEGIN=re.compile(r'^<!-- druse:begin (\S+) -->$')
END='<!-- druse:end -->'

def program(path):
    src=open(path).read()
    src=src[src.index('package '):]                       # drop the header comment
    src=re.sub(r'\n//[^\n]*(\n//[^\n]*)*\n(?=\S)','\n',src)  # drop teaching comments
    src=src.replace('uruquim:','druse:')                  # the collection is renamed
    return "```odin\n"+src.strip()+"\n```"

def render(page):
    out,i,lines=[],0,open(page).read().split('\n')
    while i < len(lines):
        out.append(lines[i])
        m=BEGIN.match(lines[i])
        if m:
            out.append(program(m.group(1)))
            while i < len(lines) and lines[i] != END: i+=1
            out.append(END)
        i+=1
    return '\n'.join(out)

pages=[p for p in sorted(os.listdir('docs/guide/06-cookbook')) if p.endswith('.md')]
bad=[]
for p in pages:
    full='docs/guide/06-cookbook/'+p
    new=render(full)
    if '--check' in sys.argv:
        if new != open(full).read(): bad.append(full)
    else:
        open(full,'w').write(new)
print(("cookbook drift check: " + (", ".join(bad)+" DIFFER" if bad else "every page matches its source"))
      if '--check' in sys.argv else f"regenerated {len(pages)} cookbook pages")
sys.exit(1 if bad else 0)
