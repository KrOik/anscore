import run_tests as rt
import hashlib,json
def main():
 hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in rt.SOURCES}
 rt.TB=rt.TB.replace('ce=cyc%19>3;m_ready=rng[3];','ce=1;m_ready=1;').replace('integer sent=0,got=0,cyc=0;','integer sent=0,got=0,cyc=0,previous_output=0;').replace('if(ce&&m_valid&&m_ready)begin','if(ce&&m_valid&&m_ready)begin\nif(got!=0&&cyc-previous_output!=1)$fatal(1,"throughput bubble");previous_output=cyc;')
 ei,ee=rt.encoder_vectors();di,de,_,_=rt.decoder_vectors()
 rt.simulate('encoder_throughput',0,ei[:4096],ee[:4096]);rt.simulate('decoder_throughput',1,di[:4096],de[:4096])
 assert hashes=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in rt.SOURCES}
 (rt.HERE/'throughput_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes,tokens_per_direction=4096,initiation_interval=1,scope='All consecutive emitted output cycles checked, CE1 and always-ready, real encoder and decoder independently.'),indent=2)+'\n')
if __name__=='__main__':main()
