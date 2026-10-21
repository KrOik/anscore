from pathlib import Path
import sys
HERE=Path(__file__).resolve().parent;sys.path.insert(0,str(HERE.parents[1]));import make_dsp_case
def dependencies(name):
 if name!='fft':raise ValueError('isolated FFT staging only')
 return [make_dsp_case.SV/'rtl/cip_fft_stream.v',HERE/'cip_dsp_fft.v',make_dsp_case.DSP/'rtl/cip_dsp_fft_twiddle.v']
make_dsp_case.dependencies=dependencies
if __name__=='__main__':
 sys.argv[1:1]=['--case','fft'];make_dsp_case.main()
