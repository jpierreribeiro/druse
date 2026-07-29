#!/usr/bin/env bash
# Every mechanical guarantee the documentation program asks for (§8), in one place.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 build/check_docs_symbols.py
python3 build/check_docs_arity.py
python3 build/check_docs_coverage.py
python3 build/gen_cookbook.py --check
python3 - <<'PY'
import re,os,glob,sys
bad=[]
for p in glob.glob('docs/**/*.md',recursive=True):
    d=os.path.dirname(p)
    for m in re.finditer(r'\]\(([^)#][^)]*)\)', open(p).read()):
        t=m.group(1)
        if t.startswith(('http','mailto')): continue
        if not os.path.exists(os.path.normpath(os.path.join(d,t))): bad.append(f"{p} -> {t}")
print("internal links:", "\n  ".join(bad) if bad else "  every link resolves")
sys.exit(1 if bad else 0)
PY
python3 - <<'PY'
import glob,sys,os
CAP={'01-concepts':150,'02-build-notes':250,'03-subjects':120,'04-rules':200,
     '05-recipes':90,'06-cookbook':400}
bad=[]
for p in glob.glob('docs/guide/**/*.md',recursive=True):
    d=os.path.basename(os.path.dirname(p))
    n=sum(1 for _ in open(p))
    if d in CAP and n > CAP[d]: bad.append(f"{p}: {n} > {CAP[d]}")
print("size budgets:", "\n  ".join(bad) if bad else "  every page within budget")
sys.exit(1 if bad else 0)
PY
echo "documentation checks: all green"
