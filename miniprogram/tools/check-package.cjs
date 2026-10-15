// 保守统计整个可上传目录；阈值低于主包限制，避免资源回流。
const fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'..');
const ignored=new Set(['tests','tools','node_modules','.DS_Store','README.md','package.json','package-lock.json','tsconfig.json','types.d.ts']);
let bytes=0;const large=[];
function walk(dir){for(const entry of fs.readdirSync(dir,{withFileTypes:true})){if(ignored.has(entry.name))continue;const full=path.join(dir,entry.name);if(entry.isDirectory())walk(full);else {const size=fs.statSync(full).size;bytes+=size;if(size>300*1024)large.push(path.relative(root,full));if(/\.(ttf|otf|pem|crt|key|p12)$/.test(entry.name))throw Error('主包禁止大字体/证书/密钥: '+full);}}}
walk(root);console.log(JSON.stringify({estimatedPackageBytes:bytes,largestFileLimit:300*1024,large},null,2));if(bytes>1500*1024||large.length)process.exit(1);
