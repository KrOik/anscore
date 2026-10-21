from run_tests import HERE,SOURCES,PATHS,decoder_vectors,simulate
import hashlib,json
def main():
 hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES};ins,exp,invalid,valid=decoder_vectors();simulate('decoder',1,ins,exp)
 assert hashes=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
 (HERE/'decoder_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes,tokens=len(ins),reachable_disparities=sorted(PATHS),all_symbol_disparity_pairs=1024*len(PATHS),invalid_contexts=invalid,valid_or_control_contexts=valid),indent=2)+'\n')
if __name__=='__main__':main()
