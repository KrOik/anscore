"""Strict stored-file and raw-stream validation. No reference import or solve."""
import json
import re
from pathlib import Path


def ascii_lines(path):
    data=Path(path).read_bytes()
    if b'\r' in data or not data.endswith(b'\n'):raise ValueError('canonical LF fixture required')
    return data.decode('ascii').splitlines()


def stored(root):
    table=json.loads((root/'CASE_TABLE.json').read_bytes());groups={g['id']:g for g in table['groups']}
    for name,group in groups.items():
        directory=root/'fixtures'/name;doc=json.loads((directory/'expected.json').read_bytes())
        if doc['group']!=name or doc['reset_ids']!=group['reset_ids'] or [c['case']['id'] for c in doc['cases']]!=group['cases']:raise ValueError('fixed group identity')
        source=[str(len(doc['cases']))];expected=[str(len(doc['cases']))]
        for case in doc['cases']:
            c=case['case'];v=c['config'];n=doc['profile']['width']*doc['profile']['height'];w=doc['profile']['width']
            if len(case['records'])!=n or len(case['inputs'])!=n:raise ValueError('stored N tuples required')
            source.append('C '+' '.join(map(str,[c['sequence'],v['bright'],v['delta'],v['min_area'],v['max_area'],v['p'],v['q'],c['tag'],case['error']])))
            expected.append('C '+' '.join(map(str,[c['sequence'],case['error'],case['records'][0][9]])))
            for i,(a,b) in enumerate(zip(case['inputs'],case['records'])):
                if len(a)!=12 or len(b)!=13 or any(type(x) is not int for x in a+b):raise ValueError('integer tuple schema')
                if a[0]!=c['sequence'] or a[1]!=i or b[0]!=i or not 0<=a[2]<=255:raise ValueError('stored index/pixel')
                if b[8]!=case['error'] or b[9]!=case['records'][0][9] or b[10:]!=[int(i==0),int(i%w==w-1),int(i==n-1)]:raise ValueError('stored metadata')
                if b[6] not in (0,1) or b[7] not in (0,1) or (b[7] and not b[6]):raise ValueError('stored flag')
                if not b[6] and any(b[1:6]):raise ValueError('noncanonical numeric zeros')
                if b[6] and (b[3]!=b[5] or not 1<=b[3]<=n or not 0<=b[4]<n):raise ValueError('stored fraction bounds')
                if b[7] and (b[4]*v['q']>=v['p']*b[3] or not v['min_area']<=b[3]<=v['max_area']):raise ValueError('stored exact selection predicate')
                if case['error'] and any(b[1:8]):raise ValueError('error numeric zeros')
                source.append('I '+' '.join(map(str,a[1:5])))
                expected.append('O '+' '.join(map(str,b)))
            # Parent/area/root predicates use only already stored tuples.
            canonical={r[0]:r for r in case['records'] if r[6]}
            if not case['error']:
                roots=[r for r in canonical.values() if r[1]==r[0]]
                if len(roots)!=1 or roots[0][3]!=n or roots[0][7]:raise ValueError('stored root')
                for r in canonical.values():
                    if r[1] not in canonical:raise ValueError('stored canonical parent')
        source.append('END');expected.append('END')
        if ascii_lines(directory/'input.txt')!=source or ascii_lines(directory/'expected.txt')!=expected:raise ValueError('scalar fixture bytes/tuple mismatch')
        if group['reset_ids']:
            probe=ascii_lines(directory/'probe.txt')
            if probe[0]!=str(len(group['reset_ids'])) or probe[-1]!='END':raise ValueError('probe framing')
            n=doc['profile']['width']*doc['profile']['height']
            if len(probe)!=2+len(group['reset_ids'])*(n+1):raise ValueError('probe exact length')
            for offset,rid in enumerate(group['reset_ids']):
                case=next(c for c in table['probe_cases'] if c['reset_id']==rid);v=case['config']
                start=1+offset*(n+1)
                error=4 if rid==9 else 0
                if probe[start]!='C '+' '.join(map(str,[case['sequence'],v['bright'],v['delta'],v['min_area'],v['max_area'],v['p'],v['q'],case['tag'],error])):raise ValueError('probe header')
                for i,line in enumerate(probe[start+1:start+1+n]):
                    w=doc['profile']['width'];pixel=(i*(1 if rid==8 else 3))%256
                    if line!=f'I {i} {pixel} {int(i==0)} {int(i%w==w-1)}':raise ValueError('fixed probe tuple')
    cert=json.loads((root/'fixtures/CERTIFICATES.json').read_bytes())
    if cert['status']!='FIXED_CERTIFICATES_PASS' or not all(cert['obligations'].values()) or not cert['no_search'] or not cert['no_additional_cases']:raise ValueError('stored boundary certificate')
    return {'profiles':5,'main':30,'fresh':10,'reset':10,'groups':10}


def simulation(item,data,root):
    # Every raw line is parsed and matched; no permissive prefix scanning.
    lines=data.decode('ascii').splitlines();doc=json.loads((root/'fixtures'/item['group']/'expected.json').read_bytes())
    tb=(root/'sim/tb_grayscale_stable_extremal_regions.sv').read_text(encoding='utf-8').splitlines()
    finish_line=next(i+1 for i,line in enumerate(tb) if '$finish;' in line)
    footer=re.fullmatch(r'sim/tb_grayscale_stable_extremal_regions\.sv:'+str(finish_line)+r': \$finish called at ([1-9][0-9]*) \(1ps\)',lines.pop() if lines else '')
    if footer is None or int(footer.group(1))%5000:raise ValueError('exact Icarus finish footer')
    inputs=[];outputs=[];receipts=[];resets=[];probe=[];probe_outputs=[];summary=[];events=[]
    widths={'IN':12,'OUT':14,'REC':10,'RESET':6,'PIN':12,'POUT':14}
    for line in lines:
        fields=line.split(' ')
        if fields[0]=='PASS':
            if line!=f"PASS group={item['group']} cases={len(doc['cases'])} resets={len(doc['reset_ids'])}":raise ValueError('exact terminal summary')
            summary.append(line);continue
        if fields[0] not in widths or len(fields)!=widths[fields[0]]+1 or any(re.fullmatch(r'0|[1-9][0-9]*',s) is None for s in fields[1:]):raise ValueError('strict raw grammar '+line)
        row=list(map(int,fields[1:]));{'IN':inputs,'OUT':outputs,'REC':receipts,'RESET':resets,'PIN':probe,'POUT':probe_outputs}[fields[0]].append(row)
        events.append((fields[0],row[0]))
    if len(summary)!=1 or lines[-1]!=summary[0]:raise ValueError('one terminal summary required')
    expected_in=[a for case in doc['cases'] for a in case['inputs']]
    expected_out=[[case['case']['sequence'],*r] for case in doc['cases'] for r in case['records']]
    if inputs!=expected_in or outputs!=expected_out or len(receipts)!=len(doc['cases']):raise ValueError('raw full input/output tuples')
    w,h,k=doc['profile']['width'],doc['profile']['height'],doc['profile']['connectivity'];n=w*h
    # Reject reordering and any unknown/extra probe sequence, even if each
    # separately collected numerical list would otherwise look correct.
    expected_events=[]
    for ordinal,case in enumerate(doc['cases']):
        if doc['reset_ids']:
            rid=doc['reset_ids'][ordinal]
            expected_events += [('PIN',200+rid)]*(3 if rid==0 else n)
            if rid==8:expected_events += [('POUT',208)]*(n-1)
            expected_events.append(('RESET',rid))
        seq=case['case']['sequence']
        expected_events += [('IN',seq)]*n+[('OUT',seq)]*n+[('REC',seq)]
    if events!=expected_events:raise ValueError('exact interleaved raw event order')
    r=2*h*(w-1)+2*w*(h-1)+(4*(w-1)*(h-1) if k==8 else 0)
    for case,rec in zip(doc['cases'],receipts):
        seq,H,A,B,E,F,latency,count,blocked,hold=rec
        if seq!=case['case']['sequence'] or count!=n or blocked<1 or hold<2*n:raise ValueError('complete owned frame/holds')
        expected=n+1 if case['error'] else 3*256+(20+2*k)*n+w*h*(h-1)//2+2*r+2*H+3+12*n+2*A+2*B+22*E+20*F-1
        if latency!=expected or not 0<=H<=r*n//2 or not 0<=A<=n*(n-1)//2 or not 0<=B<n or not 0<=E<=B or not 0<=F<n:raise ValueError('exact work/latency')
        if case['error'] and any([H,A,B,E,F]):raise ValueError('error bypass performed numerical work')
    if [row[0] for row in resets]!=doc['reset_ids']:raise ValueError('exact reset ids')
    for rid,state,child,purpose,step,index in resets:
        good={0:state==0,1:state==1 and child==3,2:state==1 and child==22,3:state==1,
              4:state==4,5:state==11 and purpose==2 and step==4,6:state==17,
              7:state==20 and index==0,8:state==20 and index==n-1,9:state==20 and index==0}[rid]
        if not good:raise ValueError('reset predicate raw')
    if not doc['reset_ids'] and (probe or probe_outputs):raise ValueError('unexpected probe')
    if doc['reset_ids']:
        for rid in doc['reset_ids']:
            rows=[a for a in probe if a[0]==200+rid]
            expected_count=3 if rid==0 else n
            if len(rows)!=expected_count:raise ValueError('probe accepted prefix')
            case=next(c for c in json.loads((root/'CASE_TABLE.json').read_bytes())['probe_cases'] if c['reset_id']==rid)
            mask=(1<<doc['profile']['tag_w'])-1;v=case['config']
            for i,row in enumerate(rows):
                live=[v['bright'],v['delta'],v['min_area'],v['max_area'],v['p'],v['q']] if i==0 else [1-v['bright'],0,0,0,0,0]
                wanted=[200+rid,i,(i*(1 if rid==8 else 3))%256,int(i==0),int(i%w==w-1),(case['tag']^(i!=0))&mask,*live]
                if row!=wanted:raise ValueError('exact probe tuple')
        if len(probe_outputs)!=(n-1 if 8 in doc['reset_ids'] else 0):raise ValueError('exact canceled probe output prefix')
        for i,row in enumerate(probe_outputs):
            seq,index,parent,level,area,num,den,can,selected,error,tag,sof,eol,last=row
            if seq!=208 or index!=i or error!=0 or tag!=104 or [sof,eol,last]!=[int(i==0),int(i%w==w-1),0]:raise ValueError('canceled prefix metadata')
            if not 0<=parent<n or not 0<=level<=255 or not 0<=area<=n or not 0<=num<n or den!=area or can not in (0,1) or selected not in (0,1):raise ValueError('canceled prefix shape')
            if (not can and any([parent,level,area,num,den,selected])) or (can and area<1) or (selected and (not can or num>=area)):raise ValueError('canceled prefix canonical/selection shape')
    return dict(inputs=len(inputs),outputs=len(outputs),frames=len(receipts),reset_targets=len(resets),probe_inputs=len(probe),stored_only=True)

if __name__=='__main__':
    result=stored(Path(__file__).resolve().parent)
    print('STORED profiles=5 main=30 fresh=10 reset=10 groups=10 NO_MODEL')
