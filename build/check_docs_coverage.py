#!/usr/bin/env python3
# Every symbol in the public ledger must be named on a guide PAGE.
# README.md is excluded on purpose: it lists what the guide does not cover, so
# counting a mention there would let the map claim coverage it does not have.
import re,glob,sys
rows=[l.rstrip('\n').split('\t') for l in open('build/phase1-public-signatures.txt') if l.strip()]
names=[re.match(r'([A-Za-z_]\w*)',r[2].split('::')[0].strip()).group(1) for r in rows]
body="".join(open(p).read() for p in glob.glob('docs/guide/**/*.md',recursive=True)
             if not p.endswith('README.md'))
missing=[n for n in names if not re.search(r'\b'+re.escape(n)+r'\b',body)]
print(f"ledger coverage: {len(names)-len(missing)} / {len(names)} symbols taught on a guide page")
if missing:
    print("  NOT on any page:", ", ".join(sorted(missing)))
sys.exit(1 if missing else 0)
