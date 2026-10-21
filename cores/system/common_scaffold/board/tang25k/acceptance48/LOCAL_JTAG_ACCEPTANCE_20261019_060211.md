# 本机 JTAG 恢复后功能复验

2026-10-19 06:02–06:22，本机 Tang Primer 25K / GW5A-25，50 MHz，COM44 / 115200。

原定 48 个公共 IP 入口全部完成，每项 3 次实际 JTAG SRAM 烧录及 UART 逐字节比对，共 144 次通过，无失败，无需修改 RTL 或预期值。

- [本轮运行记录](restored_jtag_retest_20261019_060211.json)
- [独立审计及逐项板测链接](audit_restored_jtag_retest_20261019_060211_20261019_062242_f5a2be44.md)
- [机器可读审计](audit_restored_jtag_retest_20261019_060211_20261019_062242_f5a2be44.json)

独立审计为 AUDIT_PASS：48 项覆盖无重复遗漏，144 次 SRAM 日志/JTAG 设备识别/UART 精确匹配，202 份生产文件哈希一致；冻结测试输入、源码、网表、约束和路由证据绑定均通过。

本轮新生成的 17 份临时位流已在成功测试后按 SHA 证据删除；原有选定的 31 份位流保留。保留验收日志和冻结基线。

状态为 FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN：仅覆盖冻结的有界功能夹具。保持时间、全分辨率连续视频性能、图像质量及新增扩展库的板测尚未签核，也不代表原有 300 余核全部验收。

执行命令：

```powershell
python -B cores/system/common_scaffold/board/tang25k/acceptance48/retest_restored_jtag.py
python -B cores/system/common_scaffold/board/tang25k/acceptance48/audit_retest.py cores/system/common_scaffold/board/tang25k/acceptance48/restored_jtag_retest_20261019_060211.json
```
