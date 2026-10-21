Implemented actual RGB8->full-range BT601 Y/Cb/Cr MCU blocks, runtime444/420.
55frames /75748RGB pixels /1613568 exact sample tokens PASS independent
integer oracle. Odd/thin/fullMCU/padded edges, config snapshot, CE/backpressure
and malformed frame recovery PASS. Actual OpenCV/Pillow16384pixel audit
maximum per-channel difference1LSB. Unified entry76.582sec including protocol.
Six CE0reset phases, four malformed-marker modes +4 healthy recovery frames
(1536samples), four invalid geometry guards PASS. Initial random maximum
fixture hit VVP240sec budget; final full-capacity indexed-color band fixture
PASS61.928sec. History retained in verification_notes.json; no RTL mismatch.
Isolated synth/CHECK PASS16x16/31x33/65536x1:1065/1078/1136 LUT1..4,
303/347/281ALU,130/134/148FF,1/2/96RAM blocks,all0DSP.
No board/integrated-device-fit/timing claim. Builds/temp fixtures removed.
Commands: python -B cores/system/common_scaffold/image/jpeg_color_mcu/test_jpeg_color_mcu.py;
python -B cores/system/common_scaffold/image/jpeg_color_mcu/synth_jpeg_color_mcu.py.
All edits within assigned jpeg_color_mcu folder; no shared/JTAG changes.
