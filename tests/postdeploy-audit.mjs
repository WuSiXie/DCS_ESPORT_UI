import { chromium } from 'file:///C:/Users/wsx/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright/index.mjs';
import { writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';
const folder=resolve(process.argv[2]);
const browser=await chromium.launch({executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
const context=await browser.newContext({viewport:{width:1600,height:1000}}),page=await context.newPage(),errors=[];
page.on('pageerror',error=>errors.push(error.message));
try {
  await page.goto('http://127.0.0.1:9170/');await page.getByLabel('账号',{exact:true}).fill(process.env.DCS_ESPORT_AUDIT_USER);
  await page.getByLabel('密码',{exact:true}).fill(process.env.DCS_ESPORT_AUDIT_PASSWORD);await page.getByRole('button',{name:'登录并连接'}).click();
  await page.getByRole('heading',{name:'比赛直播',exact:true}).waitFor();await page.getByText('显示历史快照',{exact:false}).waitFor();
  const url=await page.getByRole('link',{name:'打开输出'}).getAttribute('href'),parsed=new URL(url);
  let state;
  for(let i=0;i<30;i++) {
    const response=await fetch(`${parsed.origin}/api/output/${parsed.pathname.split('/').pop()}/state`,{headers:{Authorization:`Bearer ${parsed.hash.slice(1)}`}});
    state=await response.json();if(state.events.length===35)break;await new Promise(resolve=>setTimeout(resolve,200));
  }
  assert.equal(state.source.lifecycle,'ended');assert.equal(state.source.online,false);assert.equal(state.source.snapshotFresh,false);
  assert.equal(typeof state.sourcesReceivedAt,'number');assert.equal(state.source.receivedThrough,35);assert.equal(state.events.length,35);
  assert.ok(state.events.every(event=>event.historical));assert.equal(state.source.collectorAck.state,'unverified');assert.equal(state.source.collectorAck.attempts,3);
  const output=await context.newPage();output.on('pageerror',error=>errors.push(error.message));await output.setViewportSize({width:1920,height:1080});await output.goto(url);
  await output.getByText('● 任务已结束',{exact:true}).waitFor();assert.equal(await output.locator('.broadcast-event').count(),0);await output.evaluate(()=>document.fonts.ready);await output.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  await output.screenshot({path:resolve(folder,'final-output.png'),omitBackground:true});await output.locator('body').evaluate(el=>el.style.background='#17212c');await output.screenshot({path:resolve(folder,'hud-preview.png')});await page.screenshot({path:resolve(folder,'final-control.png'),fullPage:true});
  assert.deepEqual(errors,[]);await writeFile(resolve(folder,'postdeploy-report.json'),JSON.stringify({passed:true,checks:['最终导播服务重新登录成功','历史 35 条事件不重新播报','DCS 退出后离线/结束/快照过期显示正确','最终任务环境 ACK 三次后未验证','无 JavaScript 异常'],source:state.source},null,2));
  console.log('Final deployment browser checks passed.');
} finally {await browser.close();}
