// SPDX-License-Identifier: GPL-2.0-only
const fs=require('node:fs'),path=require('node:path');
function helper(name){
  for(const folder of [process.env.OPENPOLY_DISPLAY_BIN,path.resolve(__dirname,'../../MacOS'),path.resolve(__dirname,'../../build')]){
    if(!folder)continue;const candidate=path.join(folder,name);
    try{fs.accessSync(candidate,fs.constants.X_OK);return candidate;}catch{}
  }
  throw Error(`Missing bundled display helper: ${name}`);
}
module.exports={helper};
