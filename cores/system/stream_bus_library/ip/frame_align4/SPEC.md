# frame_align4

模块：`sys_frame_align4`。版本：1.0.0。

四路按epoch拼帧；旧epoch消费丢弃并计数，未来epoch保持；缺失超时补零。

epoch从0开始；串号距离须小于2^31；输出堵塞时收集与超时年龄暂停；timeout0禁用。

独立运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py --cores frame_align4
```

端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。
