@echo off
rem DIAG build of the DSP-mapped LSTM RTL: same source as build_dsp.bat but with
rem top.DIAG=1, so each round prints the same-round LSTM double-run line
rem (DIAG A=<digest1> B=<digest2>). That line is the determinism probe: before the
rem pipelining fix it read A!=B in 27/27 rounds on silicon.
rem Outputs go to build_dspdiag\ and never touch build_oss\.
setlocal
set ROOT=D:\sipeedTANG20K
set OSS=%ROOT%\tools\oss-cad-suite\oss-cad-suite
set PATH=%OSS%\bin;%OSS%\lib;%PATH%
set PRJ=%ROOT%\cores\acceleration\snn_lstm
if not exist "%PRJ%\build_dspdiag" mkdir "%PRJ%\build_dspdiag"
cd /d "%PRJ%"

set AR=src/snn_param_rom.v src/lstm_param_rom.v src/snn_event_loader.v src/lstm_input_loader.v src/snn_sparse_conv_core.v src/lstm_temporal_core.v src/uart_tx.v src/board_report.v src/top.v

yosys.exe -p "read_verilog %AR%; read_verilog -lib %OSS%/share/yosys/gowin/cells_xtra_gw5a.v; chparam -set DIAG 1 top; synth_gowin -family gw5a -top top -json build_dspdiag/top.json; stat" > build_dspdiag\yosys.log 2>&1
if errorlevel 1 (echo YOSYS FAILED & exit /b 1)
echo YOSYS OK

nextpnr-himbaechel.exe --json build_dspdiag/top.json --write build_dspdiag/pnr.json --device GW5A-LV25MG121NES --vopt family=GW5A-25A --vopt cst=src/top.cst --vopt sspi_as_gpio > build_dspdiag\nextpnr.log 2>&1
if errorlevel 1 (echo PNMR FAILED & exit /b 1)
echo PNMR OK

%OSS%\lib\python3.exe %OSS%\bin\gowin_pack-script.py -d GW5A-25A --sspi_as_gpio -o build_dspdiag/snn_lstm_25k_dsp_diag.fs build_dspdiag/pnr.json > build_dspdiag\pack.log 2>&1
if errorlevel 1 (echo PACK FAILED & exit /b 1)
echo PACK OK
findstr /i "frequency" build_dspdiag\nextpnr.log
