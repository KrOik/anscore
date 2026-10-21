# Hough / Wiener 冻结源码复核

结果：PASS，未发现阻塞问题。证据见 `review_evidence.json`。

- Hough：复核全角度投票、同步累加存储、角度环绕及带符号 rho 的 NMS。定向仿真通过 1,225 组 NMS 组合和全部 16,380 个累加器地址。90° 非环绕约定、三角函数量化与外部库差异已有说明。
- Wiener：复核精确中心矩、噪声分支、单次最终舍入、共享乘除法、协议恢复与静态非法配置；保守计算确认 13/21/32/48 位算术宽度足够。已有 Fraction / SciPy 对照证据与冻结 RTL 绑定一致。
- 逐项核对冻结源码、脚本、文档及 ROM；复核前后哈希不变。现有功能、错误路径及综合报告的 RTL 哈希绑定通过。
- 已有最大配置综合：Hough 为 684 LUT + 55 MUX5 + 386 ALU，301 FF，11 SP + 1 SPX9，0 DSP；Wiener 为 1,280 LUT + 74 MUX5 + 616 ALU，628 FF，1 DPX9B，0 DSP。计入 ALU 后分别为 1,125 和 1,970 LUT 类单元。

执行：`python -B cores/system/common_scaffold/image/new_filter_hough_review/review.py`

仅新增本目录的审查脚本、紧凑 JSON 证据和说明；没有修改作者目录，没有重跑大回归或综合，没有访问 JTAG / 串口。定向仿真临时目录自动清理。本复核不构成新增上板验收证据。