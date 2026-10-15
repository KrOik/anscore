# 整理验证记录

本次将 22 个开发项目映射为按功能命名的包。原项目、原 Git 历史与未提交源码修改保留。新仓库与上层工作区独立，未设置远程仓库。

## 已运行

- `scripts/prepare_ip_opensource.py`：白名单导出；排除无关应用、工具链和生成文件。
- `scripts/clean_ip_intermediates.ps1`（原工作区）：按扫描清单删除 8,054 个生成文件，释放 19,128,304,658 bytes，约 17.82 GiB。保留日志、验证摘要和测试输入。清理结果见 `cleanup_summary.json`；完整删除清单保留在原工作区 `artifacts/ip_cleanup_plan.json`。
- 导出包完整性检查：44,605 个文件 SHA-256 匹配，0 个不一致。
- `python host/tvla/analyze_tvla.py --self-test`：PASS。只验证分析软件，不代表实测 TVLA 通过。
- `$env:OSS_CAD_ROOT = '<OSS CAD Suite installation>'` 后运行 `.\scripts\test_hybrid_lattice_ntt_sim.ps1`：PASS，包括蝶形、掩码重组原型、调度、连续切换、状态等价、串行 NTT、顶层状态及 UART 回归；Yosys hierarchy/proc/check 报告 0 problems。

验证环境：Windows PowerShell、Icarus Verilog（OSS CAD Suite）、Yosys 0.64+181。首次尝试仅配置 bin 路径导致 DLL 加载失败；补齐 lib 后完整回归通过。新的 env.ps1 支持 OSS_CAD_ROOT 并同时加载 bin/lib。

未运行完整器件综合布线、上板或全部功能包回归，因此不产生新的 LUT/DSP/BRAM 或时序结论。各库原有验证状态继续适用。

## 文件与许可证

根 LICENSE 为 Apache-2.0，仅适用于自主贡献。按源码版权头识别并排除了 159 份嵌入式第三方源码或其历史副本；具体依赖见 `third_party_exclusions.json` 和根 NOTICE。原工作区副本没有删除。使用相应示例时需单独提供第三方依赖。

为保护测试依赖，包内部历史结构保留；仓库一级按功能分类，manifest 功能族导航见 `IP_INDEX.md`。大于 2 MiB 的历史文件未导出，完整来源文件排除记录见 `excluded_files.json`；第三方排除单独记录。

## 发布前二次检查

发布版本移至独立的 anscore 工作副本。原 ip_cores 导出目录保留，不进行批量删除。发布树按白名单重新生成，移除历史运行目录、采集和仿真输出、本机连接信息、进度记录与旧导出清单。首次全回归结果来自原导出副本；再次导入时逐文件核对源码未改变。新提交不包含原先混有历史产物的本地提交。

原先引用的 file_manifest.json、excluded_files.json、cleanup_summary.json 为本机导出报告，已从发布树排除；原报告中的数量是当时的校验结果，不是当前发布树文件数。
