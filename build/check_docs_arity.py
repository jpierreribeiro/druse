#!/usr/bin/env python3
"""Every web.* call in the guide must match its signature in the public ledger.

The ledger is build/phase1-public-signatures.txt, the same file the public-API
gate enforces, so this cannot drift from the real surface.

Counting is done over the whole file rather than line by line: a call may span
several lines, and commas inside string literals are not argument separators.
"""
import re,glob,sys

def params(sig):
    m=re.match(r'([A-Za-z_]\w*)\s*::\s*proc\s*\(',sig)
    if not m: return None
    name=m.group(1)
    # take the parameter list only — a greedy match would swallow the return tuple
    i,depth,start=m.end()-1,0,None
    while i < len(sig):
        if sig[i]=='(':
            depth+=1
            if depth==1: start=i+1
        elif sig[i]==')':
            depth-=1
            if depth==0: break
        i+=1
    inner=sig[start:i]
    if not inner.strip(): return name,0,0
    parts,depth,cur=[],0,''
    for ch in inner:
        if ch in '([{': depth+=1
        elif ch in ')]}': depth-=1
        if ch==',' and depth==0: parts.append(cur); cur=''
        else: cur+=ch
    parts.append(cur)
    total=sum(len(x.split(':')[0].split(',')) for x in parts)   # `a, b: T` is two
    opt=sum(1 for x in parts if '=' in x.split(':',1)[-1])
    return name,total-opt,total

SIG={}
for l in open('build/phase1-public-signatures.txt'):
    p=l.rstrip('\n').split('\t')
    if len(p)>=3 and p[1]=='proc':
        r=params(p[2])
        if r: SIG[r[0]]=(r[1],r[2])

def count_args(text,open_idx):
    """Arguments between the parens: balanced, string-aware, comment-aware,
    and tolerant of a trailing comma (Odin's multi-line call style)."""
    depth,cur,n,instr=0,'',0,False
    i=open_idx
    while i < len(text):
        ch=text[i]
        if not instr and text.startswith('//',i):          # skip a line comment
            i=text.find('\n',i)
            if i<0: return None
            continue
        if ch=='"' and text[i-1]!='\\': instr=not instr
        if not instr:
            if ch in '([{': depth+=1
            elif ch in ')]}':
                depth-=1
                if depth==0:
                    if n==0 and not cur.strip(): return 0    # ()
                    if not cur.strip(): return n             # trailing comma
                    return n+1
            elif ch==',' and depth==1: n+=1; cur=''
            else: cur+=ch
        else: cur+=ch
        i+=1
    return None

bad=[]
for p in sorted(glob.glob('docs/guide/**/*.md',recursive=True)):
    text=open(p).read()
    for m in re.finditer(r'\bweb\.([a-z_]\w*)\s*\(',text):
        n=m.group(1)
        if n not in SIG: continue
        cnt=count_args(text,m.end()-1)
        if cnt is None: continue
        lo,hi=SIG[n]
        if not (lo<=cnt<=hi):
            bad.append(f"{p}:{text[:m.start()].count(chr(10))+1}  web.{n} called with {cnt}, ledger says {lo}..{hi}")
print("arity check against build/phase1-public-signatures.txt")
print("\n".join(bad) if bad else "  every web.* call matches its ledger signature")
sys.exit(1 if bad else 0)
