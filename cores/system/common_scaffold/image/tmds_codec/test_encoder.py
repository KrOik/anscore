from run_tests import HERE,SOURCES,PATHS,encoder_vectors,simulate
import hashlib,json
def main():
 hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES};ins,exp=encoder_vectors();simulate('encoder',0,ins,exp)
 assert hashes=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
 (HERE/'encoder_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes,tokens=len(ins),reachable_disparities=sorted(PATHS),all_byte_disparity_pairs=256*len(PATHS),long_data_tokens=24000),indent=2)+'\n')
if __name__=='__main__':main()
