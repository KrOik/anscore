"""Summarize exact current-source board evidence without promoting timing status."""
from pathlib import Path
import datetime
import hashlib
import json

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[4]

def read(path):
    return json.loads(path.read_text(encoding='utf-8'))

def main():
    ledger=read(HERE/'acceptance_status.json')
    if ledger['current_production_sources_match_board_candidate_count']!=48:
        raise RuntimeError('all 48 current-source bindings are required')
    snapshot=read(HERE/'FINAL_PRODUCTION_SOURCE_SHA256.json')
    for name,digest in snapshot['files'].items():
        if hashlib.sha256((ROOT/name).read_bytes()).hexdigest()!=digest:
            raise RuntimeError('production source snapshot changed: '+name)
    lines=['# 48 个公共 IP 入口功能验收记录','',
           datetime.datetime.now().astimezone().isoformat(),'',
           '48/48 个当前源码版本均有至少三次实际 JTAG SRAM 烧录及精确 UART 输出一致性记录。',
           '硬件：本机 Tang Primer 25K / GW5A-25，UART COM44 / 115200，50 MHz。',
           '范围：本批 48 个公共入口的有界参数、数值夹具、流控和异常测试；不代表原有 300 余核全部重新验证。',
           '所有结果仍为 FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN；保持时间未签核，不能作为完整时序签核。',
           '图像效果、预训练超分模型质量和大分辨率连续视频性能不在本次夹具验收范围。','',
           '| 公开入口 | LUT4 | MULT12 | 最低报告频率 MHz | SRAM/UART 次数 | 当前源码板测证据 |',
           '|---|---:|---:|---:|---:|---|']
    for entry in ledger['entries']:
        choices=[]
        for case in entry['cases']:
            if case['status']!='FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN' or case['candidate_changes_pending_integration']:
                continue
            for record in case['board']:
                if record['status']=='FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN':
                    board=read(HERE/record['path'])
                    choices.append((board.get('date',''),case,record,board))
        _,case,record,board=max(choices,key=lambda x:x[0])
        summary=read(HERE/case['path']/f'build_{board["route_attempt"]}_summary.json')
        util=summary['util'];mhz=min(summary['fmax_mhz'])
        link=record['path'].replace('\\','/')
        lines.append(f'| {entry["module"]} | {util["lut4"]} | {util["mult12"]} | {mhz:.2f} | {len(board["runs"])} | [记录]({link}) |')
    lines += ['', '当前版本文件哈希见 FINAL_PRODUCTION_SOURCE_SHA256.json；逐候选、回归与失败记录见 acceptance_status.json 和 LIVE_STATUS.md。',
              '临时仿真二进制和本轮使用后的临时位流已清理；源代码、冻结输入、布局布线结果、日志与哈希记录保留。']
    (HERE/'ACCEPTANCE_REPORT.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    print('ACCEPTANCE_REPORT_48_CURRENT_SOURCE_BOARD_ENTRIES_WRITTEN')

if __name__=='__main__':
    main()
