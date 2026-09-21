const assert=require('node:assert/strict');
const {execFileSync}=require('node:child_process');
const v=require('../driver/macos/p21-video.cjs');
const {frames}=require('../driver/macos/dl3-session.cjs');
const vectors=execFileSync(process.argv[2]||'./build/test-haar',['--vectors']);
let offset=0;const strips=[];
while(offset<vectors.length){const n=vectors.readUInt16LE(offset)+2;strips.push(vectors.subarray(offset,offset+n));offset+=n;}
assert.equal(strips.length,7);assert.equal(offset,vectors.length);
[[0,0,0],[41,41,41],[255,0,0],[0,255,0],[255,255,255]].forEach((rgb,i)=>assert.deepEqual(strips[i],v.solidStrip(0,0,rgb)));
// Independent bit reader: verify a horizontal half-step's sole Haar detail,
// and a block ramp's DC prediction across both rows of the strip.
function reader(b){let at=0;const bit=()=>{assert(at<b.length*8);return b[at>>3]>>(at++%8)&1;};return {
  unary(max,wide=false){let c=0,p=0;if(wide){while(c<max&&bit())c++;for(let i=0;i<c;i++)p=p*2+bit();}
    else{while(c<max&&bit()){p|=bit()<<c;c++;}}return [c,p];},
  esc(max,wide=false){const[c,p]=this.unary(max,wide);return c?(2**(c-1)+(p>>1))*(p&1?1:-1):0;},
  bit,
};}
for(const index of [5,6]) {
  const s=strips[index],main=reader(s.subarray(18));
  for(let i=0;i<16;i++) {
    assert.equal(main.bit(),0);assert.equal(main.bit(),0);
    const[c,p]=main.unary(7);assert.equal(64-2**c-p,index===5?1:0);
  }
  let dc=0;
  for(let i=0;i<16;i++){assert.equal(main.esc(10),0);assert.equal(main.esc(10),0);dc+=main.esc(10);assert.equal(dc,index===5?510:i*4);}
  if(index===5)for(const row of [0,1]){
    const start=s.readUInt16LE(row?14:12)+2,ac=reader(s.subarray(start));
    for(let i=0;i<8;i++)assert.equal(ac.esc(9,true),-510);
  }
}
const config=v.configuration();assert.equal(config.writes.length,576);assert.deepEqual(config.pointers,[0,28,224,420,468,492]);
for(const bank of [0,0x180000]) {
  const packets=v.solidFrame(bank,()=>[0,0,0]);assert.equal(frames(Buffer.concat(packets)).length,packets.length);
  let pointers=[];const writes=new Map();let commit;
  for(const f of packets){const b=f.subarray(16,f.length-f.readUInt16LE(10));for(let p=0;p<b.length;){const n=b.readUInt16LE(p)+2,k=b.readUInt16LE(p+2);
    assert(p+n<=b.length);
    if(k===0x80){const a=b.readUInt32LE(p+4);assert.equal(a%4,0);assert(a>=bank+0x24b0&&a+n-8<=bank+0x180000);writes.set(a,b.subarray(p+8,p+n));}
    if(k===0x180)for(let q=p+8;q<p+n;q+=4)pointers.push(b.readUInt32LE(q));
    if(k===0x81)commit=[b.readUInt32LE(p+4),b.readUInt16LE(p+8)];p+=n;
  }}
  assert.equal(pointers.length,2042);assert.deepEqual(pointers.slice(0,2),[bank,bank+28]);assert.deepEqual(commit,[bank+112,8168]);
  pointers.slice(2).forEach((a,i)=>{const b=writes.get(a);assert(b);assert.equal(b.readUInt16LE(4),(i%30)*64);assert.equal(b.readUInt16LE(6),Math.floor(i/30)*16);});
}
assert.throws(()=>v.desktopFrame(0,Buffer.alloc(1)));
assert.throws(()=>v.memory(128,0x2fffff,Buffer.alloc(4)));
const source=Buffer.concat(Array.from({length:2040},(_,i)=>v.solidStrip(i%30*64,Math.floor(i/30)*16,[0,0,0])));
const bank=new v.DesktopBank(0x180000),initial=bank.frame(source);
assert.equal(initial.changedStrips,2040);assert.equal(initial.repacked,true);
const unchanged=bank.frame(source);assert.equal(unchanged.changedStrips,0);assert.equal(unchanged.repacked,false);
assert(unchanged.packets.reduce((n,b)=>n+b.length,0)<100);
const cursor=Buffer.concat([v.solidStrip(0,0,[255,255,255]),source.subarray(v.solidStrip(0,0,[0,0,0]).length)]);
const changed=bank.frame(cursor);assert.equal(changed.changedStrips,1);assert.equal(changed.repacked,false);
assert(changed.packets.reduce((n,b)=>n+b.length,0)<256);
console.log('P21 native Haar vectors, memory bounds, pointer tables and frame commits passed');
