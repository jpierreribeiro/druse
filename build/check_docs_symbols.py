import re,glob,os,sys
CRY='/home/user/uruquim-crystals'
# alias -> package source dir(s), resolved from the real import lines
ALIAS={'web':['web'],'pg':[CRY+'/db/postgres'],'session':[CRY+'/auth/session'],
 'api_key':[CRY+'/auth/api_key'],'password':[CRY+'/auth/password'],
 'csrf':[CRY+'/csrf'],'authorization':[CRY+'/authorization'],'config':[CRY+'/config'],
 'validate':[CRY+'/validate'],'vh':[CRY+'/web/validate'],'health':[CRY+'/web/health'],
 'idempotency':[CRY+'/idempotency'],'jobs':[CRY+'/jobs'],'session_http':[CRY+'/web/session'],'csrf_http':[CRY+'/web/csrf'],'cookie':[CRY+'/web/cookie'],'memory':[CRY+'/auth/session_memory'],'notes':[CRY+'/examples/notes']}
def defs(dirs):
    out=set()
    for d in dirs:
        for f in glob.glob(os.path.join(d,'*.odin')) + (glob.glob('web/*.odin') if d=='web' else []):
            for m in re.finditer(r'^([A-Za-z_][A-Za-z0-9_]*)\s*::',open(f).read(),re.M):
                out.add(m.group(1))
    return out
CACHE={a:defs(d) for a,d in ALIAS.items()}
# lines that deliberately say a symbol does NOT exist
NEG=re.compile(r'There is no |no separate |do not exist|does not exist|Proposal|var_port')
bad=[]
for p in sorted(glob.glob('docs/guide/**/*.md',recursive=True)+['docs/STYLE.md','docs/GLOSSARY.md']):
    for i,line in enumerate(open(p),1):
        if NEG.search(line): continue
        stripped=re.sub(r'"[^"]*"','""',line)          # query names live in strings
        stripped=re.sub(r'\b\w+\.(odin|md|sql|txt)\b','',stripped)  # filenames are not symbols
        for m in re.finditer(r'\b(%s)\.([a-z_][a-z0-9_]*)\b'%'|'.join(ALIAS),stripped):
            a,s=m.groups()
            if s not in CACHE[a]: bad.append(f"{p}:{i}  {a}.{s}")
print("package-aware symbol check")
print("\n".join(bad) if bad else "  all symbol references resolve in their own package")
sys.exit(1 if bad else 0)
