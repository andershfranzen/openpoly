// SPDX-License-Identifier: GPL-2.0-only
const {spawn}=require('node:child_process');
const {helper}=require('./p21-paths.cjs');
const assert=require('node:assert/strict');

function desktopSource({seconds=60,width=1920,height=1080,refreshHz=60,report=()=>{}}={}) {
  assert(Number.isInteger(seconds)&&seconds>=0&&seconds<=3600);
  const {displaySettings}=require('./p21-display-settings.cjs');
  displaySettings({width,height,refreshHz});
  const child=spawn(helper('p21-desktop-host'),[seconds,width,height,refreshHz].map(String),{stdio:['pipe','pipe','pipe']});
  let pending=null,buffer=Buffer.alloc(0),failure=null,closed=false;
  const exit=new Promise(resolve=>child.once('close',resolve));
  function fail(error) {
    failure??=error;
    if(pending){clearTimeout(pending.timer);pending.reject(failure);pending=null;}
    if(child.exitCode===null)child.kill('SIGTERM');
  }
  child.on('error',fail);
  child.stdin.on('error',fail);
  child.on('exit',(code,signal)=>{if(!closed)fail(Error(`desktop host exited: ${code??signal}`));});
  child.stderr.on('data',b=>report(b.toString().trim()));
  child.stdout.on('data',b=>{
    if(!pending){fail(Error('unsolicited desktop frame'));return;}
    buffer=Buffer.concat([buffer,b]);
    if(buffer.length>16*1024*1024+16){fail(Error('desktop frame too large'));return;}
    if(buffer.length<16)return;
    if(buffer.toString('ascii',0,8)!=='P21FRAM1'){fail(Error('invalid desktop frame header'));return;}
    const size=buffer.readUInt32LE(8);
    if(size>16*1024*1024){fail(Error('invalid desktop frame size'));return;}
    if(buffer.length<size+16)return;
    if(buffer.length!==size+16){fail(Error('unexpected extra desktop data'));return;}
    const p=pending;pending=null;clearTimeout(p.timer);
    const result={number:buffer.readUInt32LE(12),strips:buffer.subarray(16)};buffer=Buffer.alloc(0);p.resolve(result);
  });
  return {
    capture(force=false,reducedDetail=false) {
      if(failure||closed)return Promise.reject(failure||Error('desktop source closed'));
      if(pending)return Promise.reject(Error('desktop capture already pending'));
      return new Promise((resolve,reject)=>{
        pending={resolve,reject,timer:setTimeout(()=>fail(Error('desktop capture timed out')),8000)};
        child.stdin.write(reducedDetail?'L\n':force?'R\n':'F\n');
      });
    },
    async close() {
      closed=true;
      if(pending){clearTimeout(pending.timer);pending.reject(Error('desktop source closed'));pending=null;}
      child.stdin.end();
      const timer=setTimeout(()=>child.kill('SIGKILL'),2000);
      try{await exit;}finally{clearTimeout(timer);}
    },
  };
}
module.exports={desktopSource};
