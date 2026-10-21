from run_tests import *
def main():
 rows=[]
 for bit in range(64):
  values=[0,rom(1<<bit)] if bit<56 else [0,1<<bit]
  rows.append(run(f'branch_{bit}',values,error=0 if bit<56 else 4,outputs=2 if bit<56 else 1))
 (H/'branch_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),scope='Independent multidrop wired-AND ROM pairs diverge at all64 ordered positions; valid CRC devices at0..55; malformed CRC bytes at56..63 explicitly rejected after first good ROM; includes last_discrepancy64',profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
