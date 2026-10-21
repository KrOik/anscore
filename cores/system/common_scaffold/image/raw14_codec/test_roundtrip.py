from run_tests import *
def main():
 rng=random.Random(421);p=[v for i in range(16384) for v in (i,(i*23)&16383,i^16383,(i*63)&16383)];rows=[run('chain','all_values_roundtrip',frame(p,512))]
 for w,h in [(4,1),(36,29),(124,9)]:rows.append(run('chain',f'roundtrip_{w}_{h}',frame([rng.randrange(16384) for _ in range(w*h)],w)))
 (H/'roundtrip_evidence.json').write_text(json.dumps(dict(status='PASS',sources=SOURCES,scope='Actual two-RTL pack-to-unpack wire connection with CE-qualified elastic link and random downstream backpressure; independent expected original14bit pixels and SOF/EOL',profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
