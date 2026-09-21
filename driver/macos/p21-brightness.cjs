// SPDX-License-Identifier: GPL-2.0-only
// P21 DDC/CI VCP 0x10 through the authenticated DL3 control channel.
// Measured on firmware 12.2.15: 32 backlight levels, max=31.
const assert=require('node:assert/strict');
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
function packet(data) {
  const b=Buffer.alloc(64);b.writeUInt16LE(0x36);b.writeUInt16LE(0x26,2);
  b[22]=0;b[23]=data.length;data.copy(b,24);return b;
}
function ddc(bytes) {
  return Buffer.from([...bytes,bytes.reduce((checksum,n)=>checksum^n,0x6e)]);
}
function getRequest(){return packet(ddc([0x51,0x82,0x01,0x10]));}
function setRequest(percent) {
  assert(Number.isFinite(percent)&&percent>=0&&percent<=100,'brightness must be 0–100');
  return packet(ddc([0x51,0x84,0x03,0x10,0,Math.round(percent*31/100)]));
}
function parseReply(b) {
  assert(b.length>=34&&b.readUInt16LE(2)===0x25&&b[22]===11,'invalid backlight response');
  const d=b.subarray(23,34);
  assert(d.reduce((x,n)=>x^n,0x50)===0,'backlight checksum failed');
  assert(d[0]===0x6e&&d[1]===0x88&&d[2]===2&&d[3]===0&&d[4]===0x10&&d[5]===0,'backlight query unsupported');
  const maximum=d.readUInt16BE(6),value=d.readUInt16BE(8);
  assert(maximum===31&&value<=maximum,'unexpected P21 backlight range');
  return {value,maximum,percent:Math.round(value*100/maximum)};
}
async function readBrightness(cp) {
  await delay(60);
  await cp.send(getRequest(),8);await delay(60);
  const request=Buffer.alloc(32);request.writeUInt16LE(0x15);request.writeUInt16LE(0x25,2);
  return parseReply(await cp.send(request,9));
}
async function setBrightness(cp,percent) {
  await delay(60);
  await cp.send(setRequest(percent),8);await delay(150);
  const result=await readBrightness(cp);
  assert(result.value===Math.round(percent*31/100),`backlight readback ${result.value} did not match requested ${Math.round(percent*31/100)}`);
  return result;
}
module.exports={getRequest,setRequest,parseReply,readBrightness,setBrightness};
