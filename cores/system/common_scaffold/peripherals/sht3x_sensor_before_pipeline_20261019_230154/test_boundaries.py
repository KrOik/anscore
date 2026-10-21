from run_tests import *
def main():
 rows=[run('all_zero_limit1',t=0,h=0,rep=0,limit=1),run('all_max_limit1',t=65535,h=65535,rep=2,address=0x45,limit=1),run('crc_standard_BEEF',t=0xbeef,h=0xbeef,rep=1),run('last_permitted_busy_poll',t=1,h=65534,busy=3,limit=4),run('max_legal_attempts',t=32767,h=32768,limit=65535),run('default_low_wait',rep=0,actual_wait=True),run('default_medium_wait',rep=1,actual_wait=True)]
 save('boundary_evidence.json',rows,'Raw zero/full-scale and round-neighbor values, CRC BEEF=92 fixture, read attempts1/65535, success on final permitted retry, actual default low/medium wait timing; high default tested separately')
if __name__=='__main__':main()
