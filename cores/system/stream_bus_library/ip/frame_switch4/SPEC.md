# frame_switch4

模块：`sys_frame_switch4`。版本：1.0.0。

四入四出帧锁定轮询；帧结束后释放，空闲选择需要1周期。

源必须在停顿时保持数据和目的地；缺失TLAST会保持占有，不保证此时其他源公平。

独立运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py --cores frame_switch4
```

端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。
