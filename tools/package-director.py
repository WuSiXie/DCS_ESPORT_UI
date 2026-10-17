"""Package the dependency-free local director and browser assets; no credentials."""
from pathlib import Path
import shutil
import json

root=Path(__file__).resolve().parents[1]
target=root/'dist/director'
for name in ['director','web']:
    destination=target/'src'/name;destination.mkdir(parents=True,exist_ok=True)
    for source in (root/'src'/name).iterdir():
        if source.is_file() and source.suffix in {'.mjs','.html','.css'}:shutil.copy2(source,destination/source.name)
(target/'package.json').write_text(json.dumps({'name':'dcs-esport-director','private':True,'version':'0.8.0','type':'module',
    'engines':{'node':'>=24'},'scripts':{'start':'node src/director/server.mjs'}},indent=2),encoding='utf-8')
for relative in ['implementation/director.md','implementation/server.md','protocol/browser-v1.md','protocol/hook-server-v1.md']:
    destination=target/'docs'/relative;destination.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(root/'docs'/relative,destination)
(target/'README.md').write_text('# DCS 导播服务 0.8.0\n\n需要 Node.js 24 或以上，无 npm 依赖。\n\n启动：`node src/director/server.mjs --port 9170 --upstream https://主服务器:9443`\n\n本机主服务可用 `http://127.0.0.1:9080`。打开 `http://127.0.0.1:9170/` 登录。\n\n完整说明见 [导播使用说明](docs/implementation/director.md)。\n',encoding='utf-8')
print(f'Packaged director at {target}; Node.js 24+ required, no npm dependencies.')
