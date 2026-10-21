from run_tests import *
def main():
 rows=[run('nack_write_address',nack=1),run('nack_command_high',nack=2),run('nack_command_low',nack=3),run('crc_temperature',badcrc=1),run('crc_humidity',badcrc=2),run('crc_both',badcrc=3),run('busy_exhausted',busy=9,limit=3),run('busy_limit1',busy=1,limit=1),run('abort_measurement_wait',abort=1)]
 save('error_evidence.json',rows,'Explicit write/address NACKs; distinct temperature/humidity CRC flags; busy retry exhaustion at limit1/3; abort STOP; error never claims engineering validity; response hold/reset')
if __name__=='__main__':main()
