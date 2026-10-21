# 新三核只读验收审计

范围：`seam_find`、`poisson_blend`、`phase_correlation` 的 RTL、接口、算法、测试和综合证据；不操作 JTAG，不修改被审目录或共享清单。

复现：

```powershell
python -B cores/system/common_scaffold/image/new_three_review/audit.py
```

脚本先校验冻结文件及全部测试/综合证据绑定的 RTL SHA256，然后在 `TemporaryDirectory` 复制源代码，执行原始测试。测试产生的证据也仅写入副本。结束时核对原目录源码/ROM，允许 Root 并行回归刷新报告，并清理副本、测试台、二进制文件。执行结果见 `audit_evidence.json`；综合未重复执行，本次核对已有综合报告与当前 RTL 的哈希关联及资源统计。

本次四组副本测试均实际 PASS。最初脚本把报告也纳入“完全不变”门禁，因此在最终检查因 Root 同时执行 72 项回归刷新报告而失败；Root 已确认报告更新来源。冻结代码/ROM在审计前后均匹配。审计脚本已区分源码与报告，但按 Root 指令没有再次运行已通过的测试；JSON 明确记录此情况，不伪称全目录字节未变。

| 核 | 实际算法及接口审查 | 综合资源上界 |
|---|---|---|
| seam_find | 完整带代价三邻接 DP、前驱存储、回溯、逐像素硬切/羽化 mask；非固定中线。无效配置保留旧配置，marker 错误在捕获阶段进入 held DONE；abort 与多阶段 CE=0 reset 后可恢复。 | 1659 LUT1..4 + 132 MUX5 + 1 MUX6，653 FF，0 DSP |
| poisson_blend | 四邻接离散 Poisson、可选逐边 mixed gradient、signed Q8 Gauss-Seidel、真实残差复扫、重建输出；非加权融合。外圈及 mask 洞固定目标值；非法 START 保留统计，marker 错误完成固定长度帧后上报，reset 可中止。 | 最大尺寸 848 LUT1..4 + 83 MUX5 + 3 MUX6，367 FF，0 DSP |
| phase_correlation | 两次二维 FFT、共轭复乘、欧氏幅度平方根归一化、二维 IFFT、实峰搜索；非 SAD。完整同步系数 RAM；固定帧长 marker 错误、纹理不足/峰歧义显式 invalid/error，held result/DONE 与十阶段复位恢复。 | SIDE32 为 2250 LUT1..4 + **1622 ALU** + 173 MUX5，1395 FF，0 DSP |

三者均低于独立 15K LUT-class / 4 DSP 限制。phase 的 ALU 已计入保守资源估计（共 4045 LUT/ALU/MUX cells），没有遗漏到仅 LUT1..4 的数字。这里只是独立综合资源，不代表多个核同时实例化后的总资源，也不是布局布线时序或板测结论。

没有发现阻断级算法占位、冻结哈希漂移、显式错误恢复违约或资源超限。以下边界需要交付时保持清楚：

- seam 的 OpenCV DP seam finder 目标函数/端点不同，只有同定义 OpenCV filter2D 代价场声称精确一致；任意 OpenCV mask 不作为等价金标。
- Poisson 到迭代上限可能尚未收敛，必须读取 `converged` 和残差。极值 32×32 固定 32 轮的未裁剪解偏差可以较大，已有证据原样保留。输出 clipping 不等于求解收敛；OpenCV seamlessClone 比较未声称等价。
- Poisson ready 由 CE/state 控制，未额外用 rst_n 门控。同步复位沿不处理事务；集成上游应在复位时清 valid。现文档未承诺 rst_n=0 时 ready=0，因此不是当前接口违约。
- phase 仅支持 8/16/32 方形帧的环绕整数位移；近似峰强度不是 OpenCV response，也未实现子像素或一般图像匹配置信度。

Poisson 和 phase 分别拥有全文件冻结索引；seam 的 manifest/测试/错误测试/综合报告都绑定当前 RTL SHA。本审计额外记录三目录全部现有文件的 SHA256，便于交付包核对。有限测试、仿真/综合通过不扩展为全分辨率画质保证或硬件验收声明。
