// SPDX-License-Identifier: GPL-2.0-only
// DL3 wire and cryptographic construction informed by FireBurn/linux vino-v3:
// drivers/gpu/drm/vino/{proto,ake,hdcp,cp,session}.rs (GPL-2.0).
// Ordering checked against the attached P21, firmware 12.2.15.
const crypto=require('node:crypto');
const assert=require('node:assert/strict');
const WHITEN=Buffer.from('26abee3893d0c4326143a4bf5b45d6ec','hex');
const xor=(a,b)=>{assert.equal(a.length,b.length);return Buffer.from(a.map((v,i)=>v^b[i]));};
const hmac=(k,b)=>crypto.createHmac('sha256',k).update(b).digest();
function aes(k,b){const c=crypto.createCipheriv('aes-128-ecb',k,null);c.setAutoPadding(false);return Buffer.concat([c.update(b),c.final()]);}
function twice(b){const r=Buffer.alloc(16);let carry=0;for(let i=15;i>=0;i--){r[i]=(b[i]<<1)|carry;carry=b[i]>>7;}if(carry)r[15]^=0x87;return r;}
function cmac(k,b){const k1=twice(aes(k,Buffer.alloc(16))),k2=twice(k1),n=Math.max(1,Math.ceil(b.length/16));let last=Buffer.alloc(16),x=Buffer.alloc(16);b.subarray((n-1)*16).copy(last);if(b.length&&b.length%16===0)last=xor(last,k1);else{last[b.length%16]=0x80;last=xor(last,k2);}for(let i=0;i<n-1;i++)x=aes(k,xor(x,b.subarray(i*16,i*16+16)));return aes(k,xor(x,last));}
function frame(type,sub,aux,seq,body=Buffer.alloc(0)){
  assert(body.length<=65523);const h=Buffer.alloc(16);h.writeUInt16LE(12+body.length,2);h.writeUInt32LE(type,4);h.writeUInt16LE(sub,8);h.writeUInt16LE(aux,10);h.writeUInt32LE(seq,12);return Buffer.concat([h,body]);
}
function frames(b){const result=[];for(let p=0;p<b.length;){assert(b.length-p>=16,'short header');const n=b.readUInt16LE(p+2)+4;assert(b.readUInt16LE(p)===0&&n>=16&&n<=b.length-p,'invalid frame');result.push(b.subarray(p,p+n));p+=n;}return result;}
class FrameDecoder {
  constructor(){this.buffer=Buffer.alloc(0);}
  feed(chunk){
    assert(Buffer.isBuffer(chunk)&&chunk.length<=1024*1024,'invalid receive chunk');
    const b=Buffer.concat([this.buffer,chunk]),out=[];let p=0;
    while(b.length-p>=16){const n=b.readUInt16LE(p+2)+4;assert(b.readUInt16LE(p)===0&&n>=16,'invalid frame header');if(b.length-p<n)break;out.push(b.subarray(p,p+n));p+=n;}
    this.buffer=Buffer.from(b.subarray(p));assert(this.buffer.length<65540,'receive buffer overflow');return out;
  }
}
function ake(counter,id,payload=Buffer.alloc(0)){
  const formats={2:[48,0x22,0xc],0x13:[48,0x1f,0xf],4:[160,0x9a,4],9:[48,0x22,0xc],0xb:[64,0x32,0xc],0xf:[48,0x2a,4],0x10:[48,0x2d,1]};
  const [size,inner,aux]=formats[id]||[];assert(size,'unknown AKE message');assert(payload.length<=size-28);
  const b=Buffer.alloc(size);b.writeUInt16LE(inner);b.writeUInt16LE(0x10,2);b.writeUInt32LE(counter,4);b.writeUInt32LE(0x30,22);b[27]=id;payload.copy(b,28);return frame(4,4,aux,0,b);
}
function dkey(km,rtx,rrx,rn,n){const iv=Buffer.concat([rtx,rrx]);iv[15]^=n;const k=Buffer.from(km);for(let i=0;i<8;i++)k[8+i]^=rn[i];return aes(k,iv);}
function derive(km,rtx,rrx){return Buffer.concat([dkey(km,rtx,rrx,Buffer.alloc(8),0),dkey(km,rtx,rrx,Buffer.alloc(8),1)]);}
function eks(km,rtx,rrx,rn,ks){const mask=dkey(km,rtx,rrx,rn,2);for(let i=0;i<8;i++)mask[8+i]^=rrx[i];return xor(ks,mask);}
function crypt(k,nonce,seq,b){const iv=Buffer.alloc(16);nonce.copy(iv);iv.writeUInt32BE(seq,12);const c=crypto.createCipheriv('aes-128-ctr',k,iv);return Buffer.concat([c.update(b),c.final()]);}
function mac(k,nonce,seq,b){const h=Buffer.alloc(16);nonce.copy(h);h[0]^=0x80;h.writeBigUInt64BE(BigInt(seq),8);return cmac(k,Buffer.concat([h,b]));}
function seal(k,nonce,seq,aux,b){const ct=crypt(k,nonce,seq,b);return frame(4,0x24,aux,seq,Buffer.concat([ct,mac(k,nonce,seq,ct)]));}
function open(k,nonce,f){if(f.length<32)return null;const seq=f.readUInt32LE(12),ct=f.subarray(16,-16);if(!crypto.timingSafeEqual(mac(k,nonce,seq,ct),f.subarray(-16)))return null;return crypt(k,nonce,seq,ct);}
function eq(a,b,label){assert(a.length===b.length&&crypto.timingSafeEqual(a,b),label+' verification failed');}
async function establish(io,report=()=>{}){
  // Only observed P21 control requests. No configuration changes or reset.
  await io.control('c1 fe 0 1 10');
  // This observed firmware-capability query stalls on the attached P21.
  try{await io.control('c1 fc 0 1 3');}catch(e){if(e.message!=='ERR -9 for C')throw e;report('optional capability request unsupported');}
  await io.control('40 24 0 0 0');await io.control('c1 22 1 0 1c');
  await io.write(frame(1,0,0,0));const b25=Buffer.alloc(16);b25.writeUInt16LE(5);b25.writeUInt16LE(8,2);await io.write(frame(2,0x25,0,0,b25));
  await io.control('80 6 303 409 2');await io.control('80 6 303 409 1e');
  const b4=Buffer.alloc(16);b4[0]=4;const probe=Buffer.alloc(32);probe[0]=0x14;probe[2]=0x90;
  await io.write(Buffer.concat([frame(2,4,0,0,b4),frame(4,4,0xa,0,probe)]));
  let pending=[],mailbox=[];const decoder=new FrameDecoder();
  async function next(){for(let n=0;!pending.length&&n<32;n++)pending=decoder.feed(await io.read(1000));assert(pending.length,'empty response');return pending.shift();}
  async function until(predicate,label){
    const ready=mailbox.findIndex(predicate);if(ready>=0)return mailbox.splice(ready,1)[0];
    for(let i=0;i<32;i++){let f;try{f=await next();}catch(e){throw Error(label+': '+e.message);}if(predicate(f))return f;assert(mailbox.length<128,'reply mailbox overflow');mailbox.push(f);}
    throw Error('missing '+label);
  }
  async function ack(counter){return until(f=>f.length>=22&&f.readUInt16LE(8)===0x25&&f.readUInt16LE(16)===0x14&&f.readUInt16LE(20)===counter,'ACK '+counter);}
  async function hdcp(id){const f=await until(f=>f.length>=26&&f.readUInt16LE(8)===0x25&&f[25]===id,'HDCP '+id);return f.subarray(26);}
  const start=await next();assert(start.readUInt16LE(8)===0x25,'unexpected init reply');report('plaintext transport acknowledged');
  const startAck=Buffer.alloc(32);startAck.writeUInt16LE(0x14);startAck.writeUInt16LE(0x76,2);startAck.writeUInt32LE(1,4);await io.write(frame(4,4,0xa,0,startAck));await ack(1);
  const rtx=crypto.randomBytes(8),km=crypto.randomBytes(16),rn=crypto.randomBytes(8),ks=crypto.randomBytes(16),riv=crypto.randomBytes(8);
  await io.write(ake(2,2,Buffer.concat([rtx,Buffer.alloc(3)])));await ack(2);
  // Wait for the certificate before transmitter-info. Back-to-back requests
  // can be acknowledged while the receiver is still preparing its certificate.
  const certMessage=await hdcp(3);assert(certMessage.length>=137,'short receiver certificate');const repeater=certMessage[0]!==0,cert=certMessage.subarray(1);
  const publicKey=crypto.createPublicKey({key:{kty:'RSA',n:cert.subarray(5,133).toString('base64url'),e:cert.subarray(133,136).toString('base64url')},format:'jwk'});
  await io.write(ake(3,0x13,Buffer.from('0006020002','hex')));await ack(3);
  await hdcp(0x14);const encrypted=crypto.publicEncrypt({key:publicKey,padding:crypto.constants.RSA_PKCS1_OAEP_PADDING,oaepHash:'sha256'},km);
  await io.write(ake(4,4,encrypted));const rrx=(await hdcp(6)).subarray(0,8);assert.equal(rrx.length,8);
  const kd=derive(km,rtx,rrx),hInput=Buffer.from(rtx);hInput[7]^=repeater?1:0;
  eq(hmac(kd,hInput),(await hdcp(7)).subarray(0,32),"H'");await hdcp(8);report("H' authenticated");
  await io.write(ake(5,9,rn));const lKey=Buffer.from(kd);for(let i=0;i<8;i++)lKey[24+i]^=rrx[i];eq(hmac(lKey,rn),(await hdcp(0xa)).subarray(0,32),"L'");report("L' authenticated");
  await io.write(ake(6,0xb,Buffer.concat([eks(km,rtx,rrx,rn,ks),riv])));
  assert(repeater,'P21 repeater profile changed');const list=await hdcp(0xc);assert(list.length>=16);const listHeader=list.subarray(0,-16),v=hmac(kd,listHeader);eq(v.subarray(0,16),list.subarray(-16),"V'");
  await io.write(ake(7,0xf,v.subarray(16)));await ack(7);await hdcp(0x12);
  const streams=Buffer.alloc(20);streams[4]=2;streams[8]=4;streams[15]=5;await io.write(ake(8,0x10,streams));await ack(8);
  const mInput=Buffer.from('0000000400000000000005000000000000','hex');
  eq(hmac(crypto.createHash('sha256').update(kd).digest(),mInput),(await hdcp(0x11)).subarray(0,32),"M'");report('repeater authenticated; stream ready');
  const key=xor(ks,WHITEN),nonce=Buffer.from(riv);nonce[7]^=4;
  const arm24=Buffer.alloc(16);arm24.writeUInt16LE(4);arm24.writeUInt16LE(6,2);const arm45=Buffer.alloc(16);arm45.writeUInt16LE(5);arm45.writeUInt16LE(0xe,2);
  await io.write(Buffer.concat([frame(2,0x24,0,0,arm24),frame(2,0x45,0,0,arm45)]));
  const hello=Buffer.alloc(32);hello.writeUInt16LE(0x14);hello.writeUInt16LE(9,4);crypto.randomBytes(10).copy(hello,22);
  await io.write(seal(key,nonce,0,0xa,hello));
  const reply=await until(f=>f.readUInt16LE(8)===0x45,'encrypted hello reply');
  const inboundNonce=Buffer.from(nonce);inboundNonce[7]^=1;
  const plain=open(key,inboundNonce,reply);assert(plain,'encrypted reply MAC failed');report('independent encrypted control session verified');
  return {key,nonce,rtx,rrx,publicKey,listHeader,plain,nextCounter:10,nextSequence:2,nextFrame:next};
}
function control(io,session,report){
  const inbox=[];const inbound=Buffer.from(session.nonce);inbound[7]^=1;
  async function receive(){for(let i=0;i<32;i++){const f=await session.nextFrame();if(f.readUInt16LE(8)!==0x45)continue;const b=open(session.key,inbound,f);assert(b,'invalid control reply authentication');report('control-reply',{id:b.readUInt16LE(0),sub:b.readUInt16LE(2),counter:b.readUInt16LE(4),bytes:b.length});return b;}throw Error('no encrypted response');}
  async function wait(pred){const i=inbox.findIndex(pred);if(i>=0)return inbox.splice(i,1)[0];for(let n=0;n<32;n++){const b=await receive();if(pred(b))return b;assert(inbox.length<128);inbox.push(b);}throw Error('control response missing');}
  return {
    async send(b,aux){const c=session.nextCounter;b=Buffer.from(b);b.writeUInt16LE(c,4);const sub=b.readUInt16LE(2);await io.write(seal(session.key,session.nonce,session.nextSequence,aux,b));session.nextCounter=(c+1)&0xffff;session.nextSequence+=Math.ceil(b.length/16);assert(session.nextSequence<2**32,'control session needs rekey');return wait(r=>r.readUInt16LE(4)===c&&r.readUInt16LE(2)===sub);},
    async push(id){const b=await wait(r=>r.length>=10&&r.readUInt16LE(2)===0x84&&r[9]===id);const end=b.readUInt16LE(0)+2;assert(end>=10&&end<=b.length);return b.subarray(10,end);},
  };
}
async function configureConnector(io,session,report=()=>{}){
  const cp=control(io,session,report);
  function simple(id,sub,prefix=[]){const b=Buffer.alloc(32);b.writeUInt16LE(id);b.writeUInt16LE(sub,2);crypto.randomBytes(10).copy(b,22);Buffer.from(prefix).copy(b,22);return b;}
  // Exact P21 startup prelude. Prefixes exclude the vendor's allocation padding.
  for(const [id,sub,prefix,aux] of [[0x14,6,[],10],[0x14,0x30,[],10],[0x15,0xb,[1],9],[0x16,0x2a,[0,1],8],[0x15,0x20,[0],9],[0x15,0x21,[0],9],[0x16,0x2a,[0,0],8],[0x16,0x2a,[0,1],8]])await cp.send(simple(id,sub,prefix),aux);
  const rtx=crypto.randomBytes(8),km=crypto.randomBytes(16),rn=crypto.randomBytes(8),ks=crypto.randomBytes(16),riv=crypto.randomBytes(8);
  function restate(counter,id,payload){const b=ake(counter,id,payload).subarray(16);b[22]=0;b[23]=1;b[24]=0;b[25]=0;crypto.randomBytes(b.length-28-payload.length).copy(b,28+payload.length);return b;}
  await cp.send(restate(0,2,rtx),12);const certMessage=await cp.push(3);assert(certMessage.length>=137);const repeater=certMessage[0]!==0,cert=certMessage.subarray(1);
  const pub=crypto.createPublicKey({key:{kty:'RSA',n:cert.subarray(5,133).toString('base64url'),e:cert.subarray(133,136).toString('base64url')},format:'jwk'});
  await cp.send(restate(0,0x13,Buffer.from('0006020002','hex')),15);await cp.push(0x14);
  const encrypted=crypto.publicEncrypt({key:pub,padding:crypto.constants.RSA_PKCS1_OAEP_PADDING,oaepHash:'sha256'},km);
  await cp.send(restate(0,4,encrypted),4);const rrx=(await cp.push(6)).subarray(0,8);assert.equal(rrx.length,8);const kd=derive(km,rtx,rrx),hIn=Buffer.from(rtx);hIn[7]^=repeater?1:0;
  eq(hmac(kd,hIn),(await cp.push(7)).subarray(0,32),"connector H'");await cp.push(8);
  await cp.send(restate(0,9,rn),12);const lk=Buffer.from(kd);for(let i=0;i<8;i++)lk[24+i]^=rrx[i];eq(hmac(lk,rn),(await cp.push(0xa)).subarray(0,32),"connector L'");
  await cp.send(restate(0,0xb,Buffer.concat([eks(km,rtx,rrx,rn,ks),riv])),12);const list=await cp.push(0xc);assert(list.length>=16);const v=hmac(kd,list.subarray(0,-16));eq(v.subarray(0,16),list.subarray(-16),"connector V'");
  await cp.send(restate(0,0xf,v.subarray(16)),4);await cp.push(0x12);
  const streams=Buffer.alloc(12);streams.writeUInt32LE(1,4);streams.writeUInt32LE(8,8);const manage=restate(0,0x10,streams);manage.writeUInt16LE(0x26);await cp.send(manage,8);
  const ready=await cp.push(0x11);const mData=Buffer.from('00000008000000000000','hex');eq(hmac(crypto.createHash('sha256').update(kd).digest(),mData),ready.subarray(0,32),"connector M'");
  const announce=Buffer.alloc(16);announce.writeUInt16LE(8);announce.writeUInt16LE(6,2);await io.write(frame(2,8,0,0,announce));
  const caps=await cp.send(simple(0x14,0x30),10);await cp.send(simple(0x19,0x31,[0,0,0x10,0,8]),5);
  const key=xor(ks,WHITEN),nonce=Buffer.from(riv);nonce[7]^=8;
  report('independent connector authenticated and opened',{capabilityBytes:caps.length});
  return {cp,key,nonce,caps};
}
module.exports={WHITEN,xor,aes,cmac,frame,frames,FrameDecoder,ake,derive,eks,hmac,seal,open,establish,configureConnector};
