# 滤波 IP 外部设计参考

核对日期：2026-10-17。此处哈希是所列 URL 当日下载内容的 SHA-256；`main` 页面或 API 快照会随上游更新。公开源码只用于结构评估，没有逐字节复制到本地生产 RTL。

| 来源 / 本地下载快照 | URL | SHA-256 | 本地采用范围及差异 |
| --- | --- | --- | --- |
| Bert Dobbelaere，N=9 median network 页面（365,999 bytes） | https://bertdobbelaere.github.io/median_networks.html#N9L19D7 | `58e255b7dead355b17d2feef0624079e39edd2aa6fe71af3411062e72d62ecec` | 页面列出 9 输入、19 个 compare-exchange、7 层网络。本地冻结实现仍是自写的 9 层 odd-even 网络；没有照抄该网络。 |
| nextpnr PR #1850 的 GitHub API JSON 快照（15,946 bytes） | https://api.github.com/repos/YosysHQ/nextpnr/pulls/1850 | `f8ca8cc92c96f3711cc231b86945930732a3c920b7cd686479ac67191595e115` | 2026-10-17 快照状态为 open、merged=false；主题为 Gowin LUT1/2/3 timing arcs。该修复用于本地派生时序数据库评估，不修改本地 RTL。 |
| AMD Vitis Vision `xf_erosion.hpp` 上游 raw 文件（15,369 bytes） | https://raw.githubusercontent.com/Xilinx/Vitis_Libraries/main/vision/L1/include/imgproc/xf_erosion.hpp | `9b8b998d392c94f2836c902fa2ca3ccfeef30707048e4d62f0a7b7f5a7a0fce5` | 只参考结构元素有效点选择与归约组织。本地核按 `PIXEL_W` 生成腐蚀中性值，并以弹性流水处理已生成的 3×3 窗口；未复制 HLS 源码或其边界窗口逻辑。 |
| AMD Vitis Vision `xf_dilation.hpp` 上游 raw 文件（17,090 bytes） | https://raw.githubusercontent.com/Xilinx/Vitis_Libraries/main/vision/L1/include/imgproc/xf_dilation.hpp | `b7e6809cfef1f4e9bd877d466326eaac5161aa3ec7b01534416a8bfc708c702e` | 只参考掩码选择与归约结构。本地不对称结构元素沿用反射偏移约定；窗口边界仍由外部窗口生成层负责。 |

## v70 mean9 ROM

v70 的均值 ROM 没有使用外部 RTL 或表格来源。ROM 由本地定义的整数关系逐地址生成：`output = floor(address / 9)`；输入流水先加 4，因此对 8-bit 九点窗口得到 `(sum + 4) / 9`。生产文件 `rtl/img_filter_mean9_rom.v` 的 SHA-256 为 `aa222c6cf439b1bb842476fb59bb8db329eb7a5d92076857935c9b6b38240fae`。该 ROM 只服务 `OP=0 && PIXEL_W=8`，其他位宽继续使用原除法逻辑。8192 个输出（4096 地址、无停顿及 CE/背压两种模式）均由独立重复减法参考核对通过；详见 `sim/production_meanrom_v70_20261017/`。

外部设计案例和页面统计仅提供背景，不构成目标器件资源、频率或功能保证；本地结论以生产 RTL 回归、候选 PNR 与板端证据为准。
