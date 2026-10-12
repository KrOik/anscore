# width_converter

模块：`sys_width_converter`。版本：1.0.0。

MODE0压缩TKEEP有效字节32→8；MODE1按4字节或TLAST聚合8→32。

下变宽零KEEP发零KEEP标记；上变宽只解释KEEP[0]，零KEEP非末拍不贡献字节，末拍刷新。

独立运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py --cores width_converter
```

端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。
