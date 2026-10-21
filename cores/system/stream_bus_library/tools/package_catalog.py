"""Writes native-port package metadata. Adapters never contribute to IP count."""
import json
import hashlib
from common import ROOT,CORES

DETAILS={
 'frame_switch4':('四入四出帧锁定轮询；帧结束后释放，空闲选择需要1周期。','源必须在停顿时保持数据和目的地；缺失TLAST会保持占有，不保证此时其他源公平。'),
 'width_converter':('MODE0压缩TKEEP有效字节32→8；MODE1按4字节或TLAST聚合8→32。','下变宽零KEEP发零KEEP标记；上变宽只解释KEEP[0]，零KEEP非末拍不贡献字节，末拍刷新。'),
 'packet_async_fifo':('同步双时钟RAM整包存储，TLAST后提交长度/请求翻转，末拍消费后确认。','共同复位；最多1包在途；超DEPTH包整体丢弃。长度总线必须在请求/确认往返期间稳定。硬件夹具采用同源同频时钟。'),
 'backpressure_isolator':('两拍存储，s_ready仅取决于寄存器占用；占用1时持续II1。','占用满时本周期即便下游释放，上游仍等下一周期。'),
 'axi_lite_interconnect':('16位地址，4个4K窗口；独立AW/W收集与读通道；未映射返回DECERR。','每方向最多1笔在途；无突发；PROT/WSTRB保留；下游无响应需结合监控器处理。'),
 'bus_timeout_monitor':('握手后计龄；响应在截止边缘优先；超时保持在途等待真实响应。','被动监控器不生成虚假完成；limit0禁用截止；年龄饱和65535；clear用于空闲计数清零。'),
 'atomic_config':('按字节写影子寄存器；commit包含同边缘写；apply_safe后整组更新。','等待应用时write_ready/commit_ready低；WORDS为2以上2的幂。'),
 'register_snapshot':('就绪时一次采样整组live、64位周期和递增snapshot_id。','一个弹性输出槽；停顿期间保持全部输出。'),
 'timestamp64':('记录输入接受边缘之前的64位计数；load优先改变随后计数。','同时load和样本接受时样本使用旧计数；64位自然回绕；单输出弹性槽。'),
 'frame_align4':('四路按epoch拼帧；旧epoch消费丢弃并计数，未来epoch保持；缺失超时补零。','epoch从0开始；串号距离须小于2^31；输出堵塞时收集与超时年龄暂停；timeout0禁用。'),
 'trigger_window':('同步环形RAM；触发拍前最多PRE拍，后POST拍；冻结后读出且保持停顿数据。','DEPTH是2的幂，PRE+POST+1≤DEPTH；单次arm；WIDTH可携带时间戳。'),
 'calibration24':('有符号24位样本×16位Q2.14增益，向负无穷取整，再加24位偏置，24位饱和。','0DSP；16次移位加法加3个寄存收尾阶段；无堵塞时输入II20，响应valid在接受后19周期。'),
 'march_controller':('完整March C-：↑w0，↑r0w1，↑r1w0，↓r0w1，↓r1w0，↑r0。','每地址10条命令；写也需要响应；比较错误继续，总线错误/超时终止done且errors>0；不声明故障覆盖率认证。'),
 'fault_injector':('按接受拍相位进行XOR/stuck0/stuck1；非法模式返回原值并报错。','仅功能注错；不是物理故障或安全防护证明；period0每个启用拍触发。'),
 'stream_metrics':('16槽时间戳队列，计数接受/消费/阻塞，测顺序流延迟和输出间隔。','适合顺序1:1流；输入超过16个未完成报错。聚合/拆分/丢弃流只能使用计数与replay总周期，延迟不适用。'),
 'capture_replay':('主机空闲加载96位刺激；同步RAM预取，II1回放；原始192位响应保存/同步读回。','默认深度256；主机须写全引用行；输入/输出长度可不同；显式长度错误和截止超时；无RAM内容初始化。')}

def main():
    (ROOT/'doc').mkdir(exist_ok=True)
    rows=['# 新增16个系统IP','', '|序号|核|类别|功能|','|---:|---|---|---|']
    for i,(name,family,description) in enumerate(CORES):
        d=ROOT/'ip'/name; d.mkdir(parents=True,exist_ok=True)
        rtl=ROOT/'rtl'/('sys_'+name+'.v'); behavior,limit=DETAILS[name]
        manifest=dict(schema='production-system-ip-v1',ip_name=name,core_module='sys_'+name,family=family,version='1.0.0',
             source=rtl.relative_to(ROOT).as_posix(),dependencies=[],interface='native ports; see RTL declaration',
             clock_domain='dual,common-reset' if name=='packet_async_fifo' else 'single',
             description=behavior,limits=limit,rtl_sha256=hashlib.sha256(rtl.read_bytes()).hexdigest(),
             testbench='sim/native_tests.py:'+name,reference_model='models/reference.py',
             board_profile=0,board_selection=i,board_adapter='board/sys_native_adapters.v',
             qualification='engineering-qualified configurations; source-bound acceptance in doc/ACCEPTANCE.json',
             provenance='new RTL authored in this workspace; no external RTL copied into these16 sources')
        (d/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        (d/'SPEC.md').write_text(f'# {name}\n\n模块：`sys_{name}`。版本：1.0.0。\n\n{behavior}\n\n{limit}\n\n独立运行：\n\n```powershell\npython cores/system/stream_bus_library/tools/verify.py --cores {name}\n```\n\n端口、参数和有效位宽以随包RTL声明为准。模块无第三方RTL依赖。板级适配器只是测试夹具，不是额外IP；其受测模式见项目PROTOCOL.md。验证结果只适用于记录的源代码、参数和条件。\n',encoding='utf-8')
        rows.append(f'|{i}|[{name}](../ip/{name}/SPEC.md)|{family}|{behavior}|')
    (ROOT/'doc/CATALOG.md').write_text('\n'.join(rows)+'\n',encoding='utf-8')
    print('Packaged native IP count=16; adapters count=0')

if __name__=='__main__': main()
