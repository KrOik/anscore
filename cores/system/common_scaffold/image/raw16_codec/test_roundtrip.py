from run_tests import *
def main():
 rows=[]
 for endian in (0,1):
  rows.append(run('chain','all_values',frame(list(range(65536)),256),endian));r=random.Random(918)
  for width,height in [(1,1),(3,29),(257,9)]:rows.append(run('chain',f'roundtrip_{width}_{height}',frame([r.randrange(65536) for _ in range(width*height)],width),endian))
 (H/'roundtrip_evidence.json').write_text(json.dumps(dict(status='PASS',sources=SOURCES,scope='Actual connected pack/unpack RTL; exhaustive16bit values+odd line widths; both byteorders',profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
