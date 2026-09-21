// SPDX-License-Identifier: GPL-2.0-only
const assert=require('node:assert/strict');
const resolutions=[[1920,1080],[1600,900],[1280,720],[960,540]];
function displaySettings(value={}) {
  const {width=1920,height=1080,refreshHz=60}=value;
  assert(resolutions.some(([w,h])=>w===width&&h===height),'unsupported desktop resolution');
  assert([30,60].includes(refreshHz),'unsupported desktop refresh rate');
  return {width,height,refreshHz};
}
function sameMode(a,b){return a.width===b.width&&a.height===b.height&&a.refreshHz===b.refreshHz;}
module.exports={displaySettings,sameMode};
