from pathlib import Path
import subprocess,json,hashlib,base64
H=Path(__file__).resolve().parent

def fetch(url):
 return subprocess.check_output(['curl.exe','-fsSL','--ssl-revoke-best-effort','--connect-timeout','5','--max-time','15',url],timeout=20)
def main():
 rows=[];commits={'torvalds/linux':'c03c1a14507dfaf8b856c2608f9ac216021fc222','zephyrproject-rtos/zephyr':'03b1ebca3343939ae5dbad8b51d746ea2a90ef0a'}
 for repo,branch,path,terms in [('torvalds/linux','master','include/linux/mtd/spi-nor.h',['SPINOR_OP_WREN','SPINOR_OP_RDSR','SPINOR_OP_READ','SPINOR_OP_PP','SPINOR_OP_BE_4K','SR_WIP','SR_WEL','SPINOR_OP_RDID']),('zephyrproject-rtos/zephyr','main','drivers/flash/spi_nor.c',['SPI_NOR_CMD_WREN','SPI_NOR_CMD_RDSR','page_size','SPI_MODE_CPOL','SPI_MODE_CPHA'])]:
  if repo not in commits:commits[repo]=json.loads(fetch(f'https://api.github.com/repos/{repo}/commits/{branch}'))['sha']
  sha=commits[repo];url=f'https://raw.githubusercontent.com/{repo}/{sha}/{path}'
  data=base64.b64decode(json.loads(fetch(f'https://api.github.com/repos/{repo}/contents/{path}?ref={sha}'))['content'])
  lines=data.decode().splitlines();rows.append(dict(repository=repo,commit=sha,url=url,sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),excerpts=[dict(line=i+1,text=x) for i,x in enumerate(lines) if any(t in x for t in terms)][:24]));print(repo,len(data),flush=True)
 (H/'references.json').write_text(json.dumps(dict(sources=rows,notes=['Linux standardized command definitions are inspected for03/0b/02/20/06/05/9f and SR_WIP/SR_WEL.','Zephyr page-limited program/readiness policies inform whole-page preload, page crossing rejection, WEL confirmation and bounded WIP polling.','This RTL uses only standard single-lane 24bit commands. Mode0/3 choose CPOL=CPHA0/1. Physical clock and CS settings must match the selected device datasheet. No third-party RTL is copied.']),indent=2)+'\n',encoding='utf-8');print([(r['repository'],r['commit']) for r in rows])
if __name__=='__main__':main()
