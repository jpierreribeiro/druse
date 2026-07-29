#!/usr/bin/env python3
"""Every alias.symbol in the guide must exist in the package that alias imports.

A bare-name search is not enough: `pg.text` once passed because web/template
defines an unrelated `text`. Each alias therefore resolves to its own directory.

Most aliases live in the EXTENSION REPOSITORY (`druse-crystals`), which is a
separate checkout. When it is not beside this one, `defs()` reads no files and
every crystal symbol looks unknown -- 232 findings that say nothing about the
documentation. So the corpus is located explicitly and its absence is reported
as UNCHECKED rather than as failure, and never silently: a check that goes
vacuous without saying so is worse than one that fails.

Locate the extension repository with $DRUSE_CRYSTALS, else a sibling
directory. Set $DRUSE_CRYSTALS_REQUIRED=1 where the checkout is guaranteed
(CI) so a missing corpus fails instead of skipping.

Skipped: file names, text inside string literals (SQL query names look like
symbols), and deliberate statements that a symbol does NOT exist.
"""
import re,glob,os,sys
CRY=os.environ.get('DRUSE_CRYSTALS') or os.path.abspath('../druse-crystals')
REQUIRED=os.environ.get('DRUSE_CRYSTALS_REQUIRED')=='1'
ALIAS={'web':['web'],'pg':[CRY+'/db/postgres'],'session':[CRY+'/auth/session'],
 'api_key':[CRY+'/auth/api_key'],'password':[CRY+'/auth/password'],'csrf':[CRY+'/csrf'],
 'authorization':[CRY+'/authorization'],'config':[CRY+'/config'],'validate':[CRY+'/validate'],
 'vh':[CRY+'/web/validate'],'health':[CRY+'/web/health'],'idempotency':[CRY+'/idempotency'],
 'jobs':[CRY+'/jobs'],'session_http':[CRY+'/web/session'],'csrf_http':[CRY+'/web/csrf'],
 'cookie':[CRY+'/web/cookie'],'memory':[CRY+'/auth/session_memory'],'notes':[CRY+'/examples/notes'],
 'tpl':[CRY+'/web/template'],'html':[CRY+'/web/html'],'form':[CRY+'/web/form'],
 'redirect':[CRY+'/web/redirect'],'storage':[CRY+'/storage'],'mail':[CRY+'/mail'],
 'mail_http':[CRY+'/mail_http'],'sse':[CRY+'/web/sse'],'rate_limit':[CRY+'/rate_limit'],
 'rl':[CRY+'/web/rate_limit'],'idem':[CRY+'/web/idempotency']}
def defs(dirs):
    out=set()
    for d in dirs:
        for f in glob.glob(os.path.join(d,'*.odin')):
            for m in re.finditer(r'^([A-Za-z_]\w*)\s*::',open(f).read(),re.M): out.add(m.group(1))
    return out
# An alias is checkable only when its directory is actually there. Distinguishing
# "package absent" from "symbol absent" is the whole point: without it a missing
# sibling checkout reads as 232 documentation errors.
LIVE={a for a,d in ALIAS.items() if all(os.path.isdir(x) for x in d)}
DEAD=sorted(set(ALIAS)-LIVE)
CACHE={a:defs(ALIAS[a]) for a in LIVE}
NEG=re.compile(r'there is no|no separate|does not exist|do not exist|proposal|var_port|never use it',re.I)
FILE=re.compile(r'\.(odin|md|sql|txt|py|sh)$')
FILES=glob.glob('docs/guide/**/*.md',recursive=True)+['docs/STYLE.md','docs/GLOSSARY.md']
bad=[]
unchecked={}
for p in sorted(FILES):
    text=open(p).read()
    for m in re.finditer(r'\b(%s)\.([a-z_]\w*)\b'%'|'.join(ALIAS),text):
        a,s=m.groups()
        if a in CACHE and s in CACHE[a]: continue
        if FILE.search(m.group(0)): continue                       # a filename, not a symbol
        if NEG.search(text[max(0,m.start()-90):m.start()].replace('\n',' ')): continue
        seg=text[text.rfind('\n',0,m.start()):m.start()]
        if seg.count('"')%2==1: continue                           # inside a string literal
        where=f"{p}:{text[:m.start()].count(chr(10))+1}  {a}.{s}"
        (bad if a in LIVE else unchecked.setdefault(a,[])).append(where)
print("package-aware symbol check")
if DEAD:
    n=sum(len(v) for v in unchecked.values())
    print(f"  UNCHECKED: {len(DEAD)} of {len(ALIAS)} packages are not on disk under {CRY}")
    print(f"  UNCHECKED: {n} symbol reference(s) in the guide were NOT verified: "+", ".join(f"{a}.*" for a in DEAD))
    print("  UNCHECKED: check out druse-crystals beside this repository, or set $DRUSE_CRYSTALS, to verify them")
print("\n".join(bad) if bad else f"  every alias.symbol resolves in its own package ({len(LIVE)} package(s) checked)")
if DEAD and REQUIRED:
    print("  FAIL: $DRUSE_CRYSTALS_REQUIRED=1 and the extension repository is missing")
    sys.exit(1)
sys.exit(1 if bad else 0)
