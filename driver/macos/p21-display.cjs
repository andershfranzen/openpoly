// SPDX-License-Identifier: GPL-2.0-only
// OpenPoly's persistent display session. No vendor libraries or captured keys.
const fs=require('node:fs');
const {execFileSync}=require('node:child_process');
const {transport,vendorProcesses}=require('./p21-transport.cjs');
const {desktopSource}=require('./p21-desktop-source.cjs');
const {establish,configureConnector}=require('./dl3-session.cjs');
const {startVideo}=require('./p21-video.cjs');
const {displaySettings,sameMode}=require('./p21-display-settings.cjs');
const {readBrightness,setBrightness}=require('./p21-brightness.cjs');
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const vendorApp='/Applications/DisplayLink Manager.app';
async function stopVendor(){
  const seen=new Map(),until=Date.now()+8000;let quiet=0;
  while(Date.now()<until){
    const processes=vendorProcesses();
    if(!processes.length){if(++quiet>=3)return;}else{
      quiet=0;
      for(const {pid} of processes){
        const first=seen.get(pid);seen.set(pid,first??Date.now());
        try{process.kill(pid,first&&Date.now()-first>1500?'SIGKILL':'SIGTERM');}catch(e){if(e.code!=='ESRCH')throw e;}
      }
    }
    await delay(100);
  }
  throw Error('DisplayLink Manager did not release the display');
}
function options(argv){
  const o={seconds:30,takeOver:false,restore:true,parentPipe:false,settings:displaySettings()};
  for(let i=0;i<argv.length;i++){
    switch(argv[i]){
      case '--run':o.seconds=0;break;
      case '--seconds':o.seconds=Number(argv[++i]);if(!Number.isInteger(o.seconds)||o.seconds<1||o.seconds>3600)throw Error('seconds must be 1–3600');break;
      case '--take-over':o.takeOver=true;break;
      case '--no-restore':o.restore=false;break;
      case '--parent-pipe':o.parentPipe=true;break;
      case '--resolution':{
        const value=argv[++i]||'';if(!/^\d+x\d+$/.test(value))throw Error('resolution must be WIDTHxHEIGHT');
        [o.settings.width,o.settings.height]=value.split('x').map(Number);break;
      }
      case '--refresh':o.settings.refreshHz=Number(argv[++i]);break;
      case '--brightness':{
        o.brightness=Number(argv[++i]);
        if(!Number.isInteger(o.brightness)||o.brightness<0||o.brightness>100)throw Error('brightness must be 0–100');
        break;
      }
      default:throw Error('unknown argument: '+argv[i]);
    }
  }
  o.settings=displaySettings(o.settings);return o;
}
async function run(o,report){
  let stopped=false,io=null,desktop=null,wasRunning=false,failure=null;
  let desired=displaySettings(o.settings),activeMode=null,inputBuffer='';
  let desiredBrightness=o.brightness??null,brightnessRevision=0;
  const end=o.seconds?Date.now()+o.seconds*1000:Infinity;
  const stop=()=>{stopped=true;};
  process.on('SIGINT',stop);process.on('SIGTERM',stop);
  const input=b=>{
    inputBuffer+=b.toString();
    if(inputBuffer.length>4096){stop();return;}
    let newline;
    while((newline=inputBuffer.indexOf('\n'))>=0){
      const line=inputBuffer.slice(0,newline);inputBuffer=inputBuffer.slice(newline+1);
      if(line==='stop'){stop();continue;}
      try{
        const command=JSON.parse(line);
        if(command.command==='settings')desired=displaySettings(command);
        else if(command.command==='brightness'){
          if(!Number.isInteger(command.percent)||command.percent<0||command.percent>100)throw Error('brightness must be 0–100');
          desiredBrightness=command.percent;brightnessRevision++;
        }else throw Error('unknown display command');
      }
      catch(e){report({event:'settings-error',message:e.message});}
    }
  };
  if(o.parentPipe){process.stdin.resume();process.stdin.on('end',stop);process.stdin.on('data',input);}
  try{
    wasRunning=vendorProcesses().length>0;
    if(wasRunning){if(!o.takeOver)throw Error('DisplayLink Manager is running; stop it or use --take-over');report({state:'starting',message:'Releasing the display from DisplayLink Manager'});await stopVendor();}
    let reconnects=0;
    while(!stopped&&Date.now()<end){
      try{
        report({state:'starting',message:'Connecting to the P21'});
        io=await transport();if(stopped)break;
        const session=await establish(io),connector=await configureConnector(io,session);
        const video=await startVideo(io,connector);
        let appliedBrightness=-1;
        let count=0,frames=0,bytes=0,start=performance.now(),announced=false,lastPoll=0;
        while(!stopped&&Date.now()<end){
          if(!desktop||!sameMode(desired,activeMode)){
            report({state:'starting',message:'Applying display settings'});
            if(desktop)await desktop.close();desktop=null;
            activeMode={...desired};
            desktop=desktopSource({seconds:0,...activeMode,report:message=>report({event:'capture',message})});
            announced=false;
          }
          let captured=await desktop.capture(!announced);
          if(captured.strips.length>0x180000-0x24b0){
            captured=await desktop.capture(true,true);
            report({event:'quality',message:'Reduced fine detail for a frame exceeding display memory'});
          }
          if(captured.strips.length){
            const stats=await video.display(count++%2?0:0x180000,captured.strips);frames++;bytes+=stats.bytes;
            if(!announced){report({state:'running',message:'P21 display connected',...activeMode,panelWidth:1920,panelHeight:1080,panelRefreshHz:60});announced=true;reconnects=0;}
          }
          if(announced&&appliedBrightness!==brightnessRevision){
            const revision=brightnessRevision,percent=desiredBrightness;
            try{
              const result=percent===null?await readBrightness(connector.cp):await setBrightness(connector.cp,percent);
              report({event:'brightness',...result,requestedPercent:percent});
            }catch(e){report({event:'brightness-error',message:e.message});}
            appliedBrightness=revision;
          }
          // Keep authentication/control live even when the desktop is idle.
          if(performance.now()-lastPoll>250){await video.poll();lastPoll=performance.now();}
          const now=performance.now();
          if(now-start>=2000){report({event:'statistics',fps:Math.round(frames*10000/(now-start))/10,megabytesPerSecond:Math.round(bytes*1000/(now-start)/1e5)/10});frames=bytes=0;start=now;}
        }
      }catch(e){
        if(stopped)break;
        const disconnected=/found 0|ERR -4\b|LIBUSB_ERROR_NO_DEVICE/.test(e.message);
        if(!disconnected&&++reconnects>2)throw e;
        report({state:'waiting',message:disconnected?'Waiting for the P21 to reconnect':`Reconnecting: ${e.message}`});
      }finally{if(io){await io.close();io=null;}}
      if(!stopped&&Date.now()<end)await delay(Math.min(4000,1000*(reconnects+1)));
    }
  }catch(e){failure=e;report({state:'failed',message:e.message});}
  finally{
    if(desktop)await desktop.close();if(io)await io.close();
    if(wasRunning&&o.restore&&fs.existsSync(vendorApp)){
      try{execFileSync('/usr/bin/open',['-g','-j',vendorApp],{timeout:5000});report({event:'vendor-restored'});}catch(e){failure??=e;report({state:'failed',message:'Could not restart DisplayLink Manager: '+e.message});}
    }
    process.removeListener('SIGINT',stop);process.removeListener('SIGTERM',stop);
    report({state:failure?'failed':'stopped',message:failure?.message??'Display stopped'});
    if(o.parentPipe){process.stdin.removeListener('data',input);process.stdin.removeListener('end',stop);process.stdin.pause();}
  }
  return failure?1:0;
}
if(require.main===module){
  if(process.argv.includes('--help'))console.log('Usage: p21-display.cjs [--run | --seconds 1..3600] [--take-over] [--no-restore] [--parent-pipe] [--resolution 1920x1080|1600x900|1280x720|960x540] [--refresh 30|60] [--brightness 0..100]');
  else{let o;try{o=options(process.argv.slice(2));}catch(e){console.error(e.message);process.exitCode=2;}
    if(o)run(o,event=>console.log(JSON.stringify(event))).then(code=>{process.exitCode=code;}).catch(e=>{console.error(e.message);process.exitCode=1;});}
}
module.exports={options,run};
