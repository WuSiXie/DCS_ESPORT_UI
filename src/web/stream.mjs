export const escape = value => String(value ?? '').replace(/[&<>"']/gu, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'})[c]);
export const connectionLabel = status => ({connected:'主服务已连接',connecting:'正在连接',reconnecting:'连接中断 · 正在重连',expired:'登录已过期',logged_out:'未登录'})[status] ?? status;
export const lifecycleLabel = source => !source ? '等待任务数据' : ({running:'任务进行中',paused:'任务已暂停',ended:'任务已结束',ending:'任务结束补拉中',offline:'采集端离线'})[source.lifecycle] ?? '状态未知';
export function eventStream(url, { token, onState, onStatus = () => {} } = {}) {
  const controller = new AbortController();let retry;
  async function connect() {
    if(controller.signal.aborted) return;
    try {
      const response = await fetch(url,{headers:token?{Authorization:`Bearer ${token}`}:{},signal:controller.signal,cache:'no-store'});
      if(!response.ok) {onStatus(response.status===401?'unauthorized':'offline');retry=setTimeout(connect,2000);return;}
      onStatus('connected');const reader=response.body.getReader(),decoder=new TextDecoder();let pending='';
      while(true) {
        const {done,value}=await reader.read();if(done)break;pending+=decoder.decode(value,{stream:true});
        if(pending.length>20*1024*1024)throw new Error('frame_limit');
        let boundary;
        while((boundary=pending.indexOf('\n\n'))>=0) {
          const frame=pending.slice(0,boundary);pending=pending.slice(boundary+2);
          const data=frame.split('\n').find(line=>line.startsWith('data: '));if(data)onState(JSON.parse(data.slice(6)));
        }
      }
      onStatus('offline');
    } catch {if(!controller.signal.aborted)onStatus('offline');}
    if(!controller.signal.aborted)retry=setTimeout(connect,1500);
  }
  connect();return ()=>{controller.abort();clearTimeout(retry);};
}
