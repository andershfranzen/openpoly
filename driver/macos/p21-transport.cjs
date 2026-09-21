// SPDX-License-Identifier: GPL-2.0-only
const {spawn,execFileSync}=require('node:child_process');
const {helper}=require('./p21-paths.cjs');
const readline=require('node:readline');

function vendorProcesses(){
  const output=execFileSync(helper('p21-usb-bridge'),['--vendor-pids'],{encoding:'utf8',timeout:3000,maxBuffer:256*1024});
  return output.trim().split('\n').filter(Boolean).map(line=>{
    const match=/^(\d+)\t(.+)$/.exec(line);if(!match)throw Error('invalid vendor process listing');
    return {pid:Number(match[1]),path:match[2]};
  });
}
async function transport(){
  const child=spawn(helper('p21-usb-bridge'),['--session'],{stdio:['pipe','pipe','pipe']});
  let pending=null,failure=null,closing=false,stderr='';
  const exited=new Promise(resolve=>child.once('close',resolve));
  function fail(e){failure??=e;if(pending){clearTimeout(pending.timer);pending.reject(failure);pending=null;}if(child.exitCode===null)child.kill('SIGTERM');}
  child.on('error',fail);child.stdin.on('error',fail);
  child.stderr.on('data',b=>{stderr=(stderr+b.toString()).slice(-4096);});
  child.on('exit',(code,signal)=>{if(!closing)fail(Error(stderr.trim()||`USB bridge exited: ${code??signal}`));});
  const lines=readline.createInterface({input:child.stdout});
  lines.on('line',line=>{
    if(!pending){fail(Error('unexpected USB reply'));return;}
    const p=pending;pending=null;clearTimeout(p.timer);
    if(line.length>32773){p.reject(Error('oversized USB reply'));fail(Error('oversized USB reply'));return;}
    p.resolve(line);
  });
  async function request(command){
    if(failure)throw failure;if(closing)throw Error('USB transport closed');if(pending)throw Error('concurrent USB request');
    const response=new Promise((resolve,reject)=>{pending={resolve,reject,timer:setTimeout(()=>fail(Error('USB bridge request timed out')),4000)};});
    if(command!==null)child.stdin.write(command+'\n');
    const answer=await response;if(answer.startsWith('ERR'))throw Error(answer+' for '+command?.slice(0,1));return answer;
  }
  async function close(){
    closing=true;
    if(pending){clearTimeout(pending.timer);pending.reject(Error('USB transport closed'));pending=null;}
    child.stdin.end();const timer=setTimeout(()=>child.kill('SIGKILL'),2500);
    try{await exited;}finally{clearTimeout(timer);lines.close();}
  }
  try{if(await request(null)!=='READY')throw Error('USB bridge not ready');}catch(e){await close();throw e;}
  return {
    async write(b){if(!Buffer.isBuffer(b)||b.length>65536)throw Error('invalid bulk write');const r=await request('W'+b.toString('hex'));if(r!=='OK '+b.length)throw Error('short USB write');},
    async read(ms){const r=await request('R'+ms);if(!/^DATA (?:[0-9a-f]{2})*$/.test(r))throw Error('invalid bulk read');return Buffer.from(r.slice(5),'hex');},
    async control(setup){const r=await request('C'+setup);if(!/^DATA (?:[0-9a-f]{2})*$/.test(r))throw Error('invalid control response');return Buffer.from(r.slice(5),'hex');},
    close,
  };
}
module.exports={transport,vendorProcesses};
