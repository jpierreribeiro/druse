import re,glob,sys
# min/max argument count for each core proc, from the authoritative ledger
sig={}
for l in open('build/phase1-public-signatures.txt'):
    p=l.rstrip('\n').split('\t')
    if len(p)<3 or p[1]!='proc': continue
    m=re.match(r'([A-Za-z_]\w*)\s*::\s*proc\s*\((.*?)\)\s*(->|$)',p[2])
    if not m: continue
    name,params=m.group(1),m.group(2)
    if not params.strip(): sig[name]=(0,0); continue
    parts,depth,cur=[],0,''
    for ch in params:
        if ch in '([{': depth+=1
        if ch in ')]}': depth-=1
        if ch==',' and depth==0: parts.append(cur); cur=''
        else: cur+=ch
    parts.append(cur)
    total=sum(len(x.split(':')[0].split(',')) for x in parts)  # `a, b: T` is two params
    opt=sum(1 for x in parts if '=' in x.split(':',1)[-1])
    sig[name]=(total-opt,total)
bad=[]
for f in glob.glob('docs/guide/**/*.md',recursive=True):
    for i,line in enumerate(open(f),1):
        for m in re.finditer(r'\bweb\.([a-z_]\w*)\(',line):
            n=m.group(1)
            if n not in sig: continue
            s=line[m.end()-1:]; depth=0; arg=''
            for ch in s:
                if ch=='(': depth+=1
                elif ch==')':
                    depth-=1
                    if depth==0: break
                if depth>=1: arg+=ch
            inner=re.sub(r'"(?:[^"\\]|\\.)*"','S',arg[1:])   # commas inside strings are not separators
            if not inner.strip(): cnt=0
            else:
                d=0; cnt=1
                for ch in inner:
                    if ch in '([{': d+=1
                    elif ch in ')]}': d-=1
                    elif ch==',' and d==0: cnt+=1
            lo,hi=sig[n]
            if not (lo<=cnt<=hi): bad.append(f"{f}:{i}  web.{n} called with {cnt}, ledger says {lo}..{hi}")
print("arity check against build/phase1-public-signatures.txt")
print("\n".join(bad) if bad else "  every web.* call matches its ledger signature")
sys.exit(1 if bad else 0)
