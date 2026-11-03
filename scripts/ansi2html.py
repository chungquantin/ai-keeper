import re,sys,html
def p256(n):
    if n<16: base=[(0,0,0),(205,49,49),(13,188,18),(229,229,16),(36,114,200),(188,63,188),(17,168,205),(229,229,229),(102,102,102),(241,76,76),(35,209,139),(245,245,67),(59,142,234),(214,112,214),(41,184,219),(255,255,255)]; return base[n]
    if n<232:
        n-=16; v=[0,95,135,175,215,255]; return (v[n//36],v[(n//6)%6],v[n%6])
    g=8+(n-232)*10; return (g,g,g)
def convert(text):
    fg=bg=None; bold=dim=rev=False; out=[]; 
    for line in text.split('\n'):
        res=[]; pos=0
        spans=[]
        cur=(None,None,False,False,False)
        i=0
        buf=''
        def flush():
            nonlocal buf
            if not buf: return
            f,b,bo,di,re_=cur
            if re_: f,b=(b or (13,13,16)),(f or (220,224,232))
            st=[]
            if f: st.append('color:rgb(%d,%d,%d)'%f)
            if b: st.append('background:rgb(%d,%d,%d)'%b)
            if bo: st.append('font-weight:700')
            if di: st.append('opacity:.55')
            res.append('<span style="%s">%s</span>'%(';'.join(st),html.escape(buf)) if st else html.escape(buf)); buf=''
        for m in re.finditer(r'\x1b\[([0-9;]*)m|([^\x1b]+)|\x1b\[[0-9;?]*[A-Za-ln-z]',line):
            if m.group(2) is not None: buf+=m.group(2); continue
            if m.group(1) is None: continue
            flush()
            f,b,bo,di,re_=cur
            codes=[int(c) if c else 0 for c in m.group(1).split(';')]
            k=0
            while k<len(codes):
                c=codes[k]
                if c==0: f=b=None; bo=di=re_=False
                elif c==1: bo=True
                elif c==2: di=True
                elif c==7: re_=True
                elif c==39: f=None
                elif c==49: b=None
                elif c in (38,48) and k+1<len(codes):
                    if codes[k+1]==2: col=tuple(codes[k+2:k+5]); k+=4
                    else: col=p256(codes[k+2]); k+=2
                    if c==38: f=col
                    else: b=col
                k+=1
            cur=(f,b,bo,di,re_)
        flush()
        out.append(''.join(res))
    return '\n'.join(out)
if __name__=='__main__':
    print(convert(sys.stdin.read()))
