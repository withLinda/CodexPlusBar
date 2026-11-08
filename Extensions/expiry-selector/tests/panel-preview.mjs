// Synthetic host for browser acceptance only. Never packaged or pointed at accounts.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
const html = `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{margin:0}iframe{border:0;width:100%;height:1100px}</style><iframe src="/panel/index.html"></iframe><script>
const now=Date.now(); const status={mode:'paused',blockedReason:'paused',activeCredentialID:'b',activeLabel:'Work account',nextCredentialID:'a',snapshotAgeMs:0,holdsCount:0,checking:false,supportedVersions:{opencode:'2.2.6',openchamber:'2.7.0'},lastSwitch:null,recentHistory:[],snapshotGeneratedAtMs:now,nativeObservedAtMs:now,exclusions:[{credentialID:'c',code:'five-hour-empty'}],accounts:[{credentialID:'a',label:'Personal account',expiresAtMs:now+86400000,fiveHourRemaining:72,sevenDayRemaining:41,usageObservedAtMs:now-120000,entitlementObservedAtMs:now-3600000},{credentialID:'b',label:'Work account',expiresAtMs:now+86400000*6,fiveHourRemaining:90,sevenDayRemaining:'not-applicable',usageObservedAtMs:now-60000,entitlementObservedAtMs:now-3600000},{credentialID:'c',label:'Long-labelled shared research account@example.test',expiresAtMs:null,fiveHourRemaining:0,sevenDayRemaining:20,usageObservedAtMs:now,entitlementObservedAtMs:null}]};
window.testStatus=status; window.delayControl=0; window.failControl=false;
const dark=new URL(location.href).searchParams.has('dark'); const bg=dark?'#232a2e':'#f5f3ed',fg=dark?'#d3c6aa':'#46504b',muted=dark?'#9da9a0':'#636d65';
const tokens={background:bg,elevated:bg,foreground:fg,muted,subtle:muted,border:dark?'#414b50':'#d4d7cf',hover:dark?'#343f44':'#e4e8de',selection:'#405344',focus:'#7f9d67',primary:'#a7c080',mutedSurface:dark?'#2d363b':'#e8ede2',elevatedForeground:fg,active:'#405344',selectionForeground:fg,primaryForeground:'#232a2e',primaryText:dark?'#a7c080':'#50712e',successText:dark?'#a7c080':'#50712e',warningText:dark?'#dbbc7f':'#7d5d1e',errorText:'#d65d5d',infoText:muted,success:'#a7c080',warning:'#dbbc7f',error:'#d65d5d',info:muted,font:'system-ui,sans-serif',mono:'monospace',radius:'6px'};
addEventListener('message',async event=>{const m=event.data;if(m.channel!=='openchamber.sdk')return;const send=(type,payload,extra={})=>event.source.postMessage({channel:m.channel,v:1,type,payload,...extra},'*');if(m.type==='hello')send('ready',{theme:{mode:dark?'dark':'light',tokens},surface:'panel',directory:null,session:null,connection:{connected:true,account:''},settings:{},item:null});if(m.type==='service-request'){if(m.payload.method==='POST'){if(window.failControl){send('result',null,{id:m.id,ok:false,code:'REQUEST_FAILED',error:'fixture failure'});return;}await new Promise(r=>setTimeout(r,window.delayControl));const b=JSON.parse(m.payload.body);if(b.mode){status.mode=b.mode;status.blockedReason=b.mode==='paused'?'paused':null;}}send('result',{status:200,body:JSON.stringify(status)},{id:m.id,ok:true});}});
</script>`;
const server = createServer(async (req, res) => {
  if (req.url === '/' || req.url?.startsWith('/?')) { res.setHeader('content-type', 'text/html'); res.end(html); return; }
  const paths = { '/panel/index.html': 'text/html', '/panel/main.js': 'text/javascript' };
  if (!paths[req.url]) { res.writeHead(404); res.end(); return; }
  res.setHeader('content-type', paths[req.url]); res.end(await readFile(resolve('dist' + req.url)));
});
server.listen(4178, '127.0.0.1', () => console.log('Synthetic panel preview http://127.0.0.1:4178'));
