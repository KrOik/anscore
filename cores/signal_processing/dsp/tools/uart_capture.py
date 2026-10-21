import serial, time, sys
port = sys.argv[1] if len(sys.argv)>1 else "COM24"
secs = float(sys.argv[2]) if len(sys.argv)>2 else 15
out  = sys.argv[3] if len(sys.argv)>3 else "doc/board_uart_full.txt"
ser = serial.Serial(port, 115200, timeout=1)
time.sleep(0.3); ser.reset_input_buffer()
data=b""; t0=time.time()
while time.time()-t0 < secs:
    chunk = ser.read(4096)
    data += chunk
    if data.count(b"\n") >= 12:
        time.sleep(0.5); data += ser.read(4096); break
ser.close()
open(out,"wb").write(data)
sys.stdout.write("captured %d bytes\n" % len(data))
sys.stdout.write(data[:800].decode("ascii","replace"))
