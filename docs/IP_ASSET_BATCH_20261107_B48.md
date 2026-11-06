# B48：稀疏推理、报文载荷整形、频谱变化与 RAW 修复

基线：`3a58c99bda6f6f62a34d1c20247d3b42d8d89006`。
四条通道均交付实际 RTL、独立模型、完整离线依赖、可连接示例及有限测试。
全部新组合仍为 **HW_UNVERIFIED**，没有综合、布局布线、STA、上板、PPA
或历史工程回归。

| 通道与包 | 实际新增能力 | 实际组合示例 |
|---|---|---|
| root：`cores/acceleration/int4_sparse2of4_matvec` | U8 向量与驻留 S4 2:4 权重；每组 11 位表示、共享乘法器、精确累加与 RNE 重量化 | 四特征差分后稳定 Top-2 |
| A：`cores/communication/payload_multiflow_token_shaper` | 完整载荷存储转发、KEEP 字节计费、首拍整包扣费、独立流补充与 LAST 所有权 | 四业务类载荷整形 |
| B：`cores/signal_processing/spectral_shape_change` | 相邻归一化功率谱的精确总变差距离；参考帧仅在结果消费时提交 | signed16 I/Q 功率计算后频谱变化检测 |
| C：`cores/image_processing/raw_directional_defect_repair` | 同相位半径 2 RAW 方向性坏点检测；梯度自适应阈值与四方向选择 | 修复后 Bayer 到 RGB |

各包的 `QUALIFICATION.json`、`QUALIFICATION.md` 和 `DELIVERY.md` 给出当前状态。
原封存 README/manifest 的 pending 字段是执行前状态；后续证据由新增文件补充。
所有正式执行都先完成 root 与独立 Worker 全文审查，再校验具体源码、工具与
计划哈希。子进程限 20 秒，树终止辅助限 5 秒，目标最终退出观察只有一个
2 秒区间。仿真前先持久化当次镜像哈希与预检查标记。

七份实际回执累计 19 次数值准备、56 个 HDL 子进程：53 PASS、3 FAIL、0
TIMEOUT；其中 20 次仿真成功。三次首次失败分别为稀疏 TB 的 EOF 假设、
载荷 TB 的 Icarus 二维数组 fscanf 限制、频谱 TB 的保留字声明。失败均立即
停止并保留；三个独立修订只修复对应 TB 问题，复用原向量，分别重新审查后
执行四组编译/仿真。生产 RTL 与原模型未因此改写，没有自动重试。

RAW 包检查 122 个案例、142,620 个像素及 24 次复位恢复。频谱包检查
164 个向量案例、276 个结果、1,380 次保持观察、36 次复位、32 次取消及
4 次算术异常恢复。其余数值、载荷、配置、反压和错误计数保留在原始回执中。

本轮新增八个生产/示例 HDL 文件，并明确纳入一个已有工作区支持源
`cores/acceleration/stream_topk/rtl/stream_topk.v`。该源为原工作区原创 RTL，
采用仓库 Apache-2.0 许可，3,665 字节和源码哈希不变；基线树未包含它，
所以本次按一个新增支持依赖提交。仅纳入这一源文件；相关历史报告不作为
本轮证据。更正见稀疏包的 `DEPENDENCY_PROVENANCE.md`。另十个依赖有
精确基线 mode/type/OID 证明。继承的 188 个包与旧支持对象保持原样。

静态快照入口为 `docs/snapshots/b48/source.json` 与 `structure.json`，最终
提交证据见同目录 `closeout.json`。目标资产域为 192 包、420 个规范 HDL
源文件、422 个模块声明且无模块名冲突；实际计数由独立静态审计确认。
22 个本轮原始 VVP 镜像（包含两份失败镜像）和既有 164 个保留产物留在
被忽略的任务目录，二进制不进入 Git。既有清理拒绝继续保留，本轮不删除。
快照只证明所列离线闭包和有限测试，不代表器件资源、时序或硬件签核。
