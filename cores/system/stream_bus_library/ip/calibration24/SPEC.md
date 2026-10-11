# calibration24

模块：`sys_calibration24`。版本：1.0.0。

有符号24位样本×16位Q2.14增益，向负无穷取整，再加24位偏置，24位饱和。

0DSP；16次移位加法加3个寄存收尾阶段；无堵塞时输入II20，响应valid在接受后19周期。

独立运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py --cores calibration24
```

端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。
