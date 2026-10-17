import { chromium } from 'file:///C:/Users/wsx/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright/index.mjs';
import { writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';

const folder=resolve(process.argv[2]);
const browser=await chromium.launch({executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
const context=await browser.newContext({viewport:{width:1600,height:1000}}),errors=[],checks=[],observed=new Set();
const page=await context.newPage(),second=await context.newPage(),output=await context.newPage();
for(const tab of [page,second,output]) {tab.on('pageerror',error=>errors.push(error.message));tab.setDefaultTimeout(20000);}
async function login(tab,port) {
  await tab.goto(`http://127.0.0.1:${port}/`);
  await tab.getByLabel('账号',{exact:true}).fill(process.env.DCS_ESPORT_AUDIT_USER);
  await tab.getByLabel('密码',{exact:true}).fill(process.env.DCS_ESPORT_AUDIT_PASSWORD);
  await tab.getByRole('button',{name:'登录并连接'}).click();await tab.getByRole('heading',{name:'比赛总览',exact:true}).waitFor();
}
let last=null,screenshot=false;
try {
  await login(page,9170);await login(second,9171);
  await second.getByRole('checkbox',{name:'战场总览',exact:true}).uncheck();
  await second.getByRole('button',{name:'保存',exact:true}).click();
  assert.equal(await page.getByRole('checkbox',{name:'战场总览',exact:true}).isChecked(),true);
  await second.getByRole('checkbox',{name:'战场总览',exact:true}).check();await second.getByRole('button',{name:'保存',exact:true}).click();
  checks.push('两个部署中的独立导播服务登录并验证画面开关隔离');
  const url=await page.getByRole('link',{name:'打开输出'}).getAttribute('href'),parsed=new URL(url);
  await output.setViewportSize({width:1920,height:1080});await output.goto(url);
  const id=parsed.pathname.split('/').pop(),token=parsed.hash.slice(1);
  const began=Date.now();let ready=false;
  while(Date.now()-began<360000) {
    const response=await fetch(`${parsed.origin}/api/output/${id}/state`,{headers:{Authorization:`Bearer ${token}`}});
    assert.equal(response.status,200);last=await response.json();
    const entities=last.snapshot?.entities??[],planes=entities.filter(e=>e.kind==='aircraft'),missiles=entities.filter(e=>e.kind==='missile');
    for(const event of last.events)observed.add(event.eventSeq);
    assert.equal(new Set(last.events.map(e=>e.eventSeq)).size,last.events.length,'No duplicate UI events');
    if(planes.length&&!ready) {
      ready=true;assert.equal(planes.length,32);
      for(const plane of planes) {
        assert.equal(typeof plane.motion.speedMps,'number');assert.equal(typeof plane.fuel.ratioRaw,'number');
        assert.equal(typeof plane.occupancy.isPlayer,'boolean');assert.ok(Array.isArray(plane.armament.items));
      }
      checks.push('实际任务 32 架飞机的速度、油量、弹药与玩家身份进入导播链路');
    }
    if(missiles.length&&!screenshot) {
      for(const missile of missiles) {assert.ok(missile.launch.launcher);assert.ok(missile.targetObservation);}
      await output.locator('.missile-item').first().waitFor();
      await output.screenshot({path:resolve(folder,'live-output.png')});await page.screenshot({path:resolve(folder,'live-control.png'),fullPage:true});
      (await writeFile(resolve(folder,'live-output-state.json'),JSON.stringify(last,null,2)));
      checks.push('逐发导弹及发射者/目标已实际渲染');screenshot=true;
    }
    if(last.source?.lifecycle==='ended'&&last.source?.serverTailComplete)break;
    await new Promise(resolve=>setTimeout(resolve,500));
  }
  assert.ok(ready&&screenshot,'Live aircraft and missiles must be observed');assert.equal(last.source.lifecycle,'ended');
  assert.equal(last.source.serverTailComplete,true);assert.equal(last.events.length,last.source.receivedThrough);
  assert.deepEqual(last.events.map(e=>e.eventSeq),Array.from({length:last.source.receivedThrough},(_,i)=>i+1));
  await output.getByText('● 任务已结束',{exact:true}).waitFor();
  await output.screenshot({path:resolve(folder,'ended-output.png')});await page.screenshot({path:resolve(folder,'ended-control.png'),fullPage:true});
  checks.push('正常结束补拉全部到达浏览器，事件序号连续且无重复，输出显示历史状态');
  assert.deepEqual(errors,[]);
  await writeFile(resolve(folder,'live-browser-report.json'),JSON.stringify({passed:true,checks,errors,
    receivedThrough:last.source.receivedThrough,observedEventCount:observed.size,source:last.source},null,2));
  console.log(JSON.stringify({passed:true,checks,receivedThrough:last.source.receivedThrough}));
} catch(error) {
  await page.screenshot({path:resolve(folder,'live-browser-failure.png'),fullPage:true}).catch(()=>{});
  await writeFile(resolve(folder,'live-browser-report.json'),JSON.stringify({passed:false,checks,errors,error:String(error)},null,2));throw error;
} finally {await browser.close();}
