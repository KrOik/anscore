# Read-only build mapping for parent resource measurement

以下只是构建映射说明；本任务未执行 Yosys、综合、PNR、打包或板测。父任务将串行实际测量。基准必须使用同一份 v95 top、stats、相同 synth 选项和相同 target，以免把 harness 差异算成 divider 收益。v95 的 47 字节 UART top 只覆盖四像素统计到 gain，不覆盖完整视频 AWB feedback。

从仓库根目录执行时，令 `V95` 为 `cores/system/common_scaffold/board/tang25k/build/image_awb48_selftest_25k_20261017_v95_borrowprefix/rtl`，`DIV3` 为本目录。此处缩写用于说明，不是 Yosys 变量。`CELL_LIB` 由现有 `device_flow.cells_xtra_lib()` 返回 GW5A 库文件。

基准映射：

```text
read_verilog -sv V95/img_isp_awb_stats.v V95/img_isp_awb_autogain.v V95/image_awb48_selftest_25k.v
read_verilog -lib CELL_LIB
hierarchy -check -top image_awb48_selftest_25k
synth_gowin -noalu -family gw5a -top image_awb48_selftest_25k -json baseline.json
stat
```

候选映射可在 Yosys 内改顶层 solver module 名，不复制或修改 v95 top：

```text
read_verilog -sv DIV3/awb_constant_div3_radix4.v DIV3/img_isp_awb_autogain_div3_candidate.v
rename img_isp_awb_autogain_div3_candidate img_isp_awb_autogain
read_verilog -sv V95/img_isp_awb_stats.v V95/image_awb48_selftest_25k.v
read_verilog -lib CELL_LIB
hierarchy -check -top image_awb48_selftest_25k
synth_gowin -noalu -family gw5a -top image_awb48_selftest_25k -json candidate.json
stat
```

候选映射不要加载生产或 v95 `img_isp_awb_autogain.v`，否则与 rename 目标名称冲突。候选内的 `awb_div3_candidate_byte_divider` 和 `awb_div3_candidate_sub_prefix16` 已与旧模块区分；不需要旧 generic helper 文件。

父任务拟用的另一条等价路径：只在临时 staged top 中，把唯一的 `img_isp_awb_autogain #(.SUM_WIDTH(48)) solver_i` 改为 `img_isp_awb_autogain_div3_candidate #(.SUM_WIDTH(48)) solver_i`，其余 top 字节不变；这条路径无需上述 `rename`。原 top 文件只读，47B UART 黄金只读。原 top 中该实例匹配次数必须恰为 1。

只测 solver 大小也可分别选 `img_isp_awb_autogain` 与 `img_isp_awb_autogain_div3_candidate` 为 synth top，并对两者显式设置 `SUM_WIDTH=48`，但这种 isolated-cell 结果应与四像素 board-harness 资源分开报告。此任务尚无任何资源数值。

精确输入路径、字节数、SHA256 和最终仿真证据位于 `FREEZE_HANDOFF.json`；冻结范围仅本目录。父任务的实际 netlist/log/板测证据请放到其独占测量目录，不向本目录或 v95 写入。
