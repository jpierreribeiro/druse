#!/usr/bin/env python3
"""Every alias.symbol in the guide must exist in the package that alias imports.

A bare-name search is not enough: `pg.text` once passed because web/template
defines an unrelated `text`. Each alias therefore resolves to its own directory.

Skipped: file names, text inside string literals (SQL query names look like
symbols), and deliberate statements that a symbol does NOT exist.
"""
import re,glob,os,sys
CRY='/home/user/uruquim-crystals'
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
CACHE={a:defs(d) for a,d in ALIAS.items()}
NEG=re.compile(r'there is no|no separate|does not exist|do not exist|proposal|var_port|never use it',re.I)
FILE=re.compile(r'\.(odin|md|sql|txt|py|sh)$')
FILES=glob.glob('docs/guide/**/*.md',recursive=True)+['docs/STYLE.md','docs/GLOSSARY.md']
bad=[]
for p in sorted(FILES):
    text=open(p).read()
    for m in re.finditer(r'\b(%s)\.([a-z_]\w*)\b'%'|'.join(ALIAS),text):
        a,s=m.groups()
        if s in CACHE[a]: continue
        if FILE.search(m.group(0)): continue                       # a filename, not a symbol
        if NEG.search(text[max(0,m.start()-90):m.start()].replace('\n',' ')): continue
        seg=text[text.rfind('\n',0,m.start()):m.start()]
        if seg.count('"')%2==1: continue                           # inside a string literal
        bad.append(f"{p}:{text[:m.start()].count(chr(10))+1}  {a}.{s}")
print("package-aware symbol check")
print("\n".join(bad) if bad else "  every alias.symbol resolves in its own package")
sys.exit(1 if bad else 0)
