import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
const home=process.env.AC_RELAY_HOME||'/var/lib/agent-control-relay';await fs.mkdir(home,{recursive:true,mode:0o700});
const file=path.join(home,'devices.json'),codesFile=path.join(home,'codes.json');
let devices=[],codes=[];try{devices=JSON.parse(await fs.readFile(file,'utf8'));}catch(e){if(e.code!=='ENOENT')throw e;}try{codes=JSON.parse(await fs.readFile(codesFile,'utf8'));}catch(e){if(e.code!=='ENOENT')throw e;}
const hash=v=>crypto.createHash('sha256').update(v||'').digest('hex');let writes=Promise.resolve();
const save=(name,value)=>{const data=JSON.stringify(value);writes=writes.catch(()=>{}).then(async()=>{await fs.writeFile(name+'.tmp',data,{mode:0o600});await fs.rename(name+'.tmp',name);});return writes;};
if(process.argv.includes('--create-code')){const code=crypto.randomBytes(12).toString('hex');codes.push({hash:hash(code),expires:Date.now()+600000});await save(codesFile,codes);console.log(code);process.exit(0);}
let enrolling=false;
const pending=new Map(),queues=new Map(),waiters=new Map();
function json(res,status,data){res.writeHead(status,{'content-type':'application/json','cache-control':'no-store'});res.end(JSON.stringify(data));}
async function bytes(req,max=8*1024*1024){const values=[];let length=0;for await(const chunk of req){length+=chunk.length;if(length>max)throw Object.assign(Error('请求过大'),{status:413});values.push(chunk);}return Buffer.concat(values);}
function authorized(req,d){return d&&hash(req.headers['x-device-key'])===d.keyHash;}
const rate=new Map();
const server=http.createServer(async(req,res)=>{try{
 const url=new URL(req.url,'http://local');if(req.headers.origin)return json(res,403,{error:'仅允许原生客户端'});
 if(url.pathname==='/control/enroll'&&req.method==='POST'){
  if(enrolling)return json(res,409,{error:'注册正在处理，请重试'});enrolling=true;try{codes=JSON.parse(await fs.readFile(codesFile,'utf8').catch(()=>"[]"));
  const b=JSON.parse((await bytes(req,8192)).toString()),code=codes.find(c=>c.hash===hash(b.code)&&c.expires>Date.now());
  if(!code){const key=req.socket.remoteAddress,old=rate.get(key)||{n:0,until:Date.now()+60000};if(old.until<Date.now()){old.n=0;old.until=Date.now()+60000;}old.n++;rate.set(key,old);return json(res,old.n>10?429:403,{error:'连接码无效或已过期'});}
  if(typeof b.phoneTokenHash!=='string'||!/^[a-f0-9]{64}$/.test(b.phoneTokenHash))return json(res,400,{error:'设备配对标识无效'});
  if(devices.length>=64)return json(res,409,{error:'设备数量已达到上限'});
  const id=crypto.randomUUID(),key=crypto.randomBytes(32).toString('hex');
  codes=codes.filter(c=>c!==code);await save(codesFile,codes);
  devices.push({id,name:String(b.name||'电脑').slice(0,80),keyHash:hash(key),phoneTokenHash:b.phoneTokenHash});await save(file,devices);
  return json(res,201,{id,key,basePath:'/d/'+id});
  }finally{enrolling=false;}
 }
 const match=url.pathname.match(/^\/control\/([a-f0-9-]{36})\/(poll|result)$/);
 if(match){const d=devices.find(d=>d.id===match[1]);if(!authorized(req,d))return json(res,401,{error:'设备授权无效'});
  if(match[2]==='poll'&&req.method==='GET'){
   if(waiters.has(d.id))return json(res,409,{error:'设备已有连接'});
   if(!(queues.get(d.id)||[]).length){await new Promise(resolve=>{const timer=setTimeout(done,20000);function done(){clearTimeout(timer);waiters.delete(d.id);resolve();}waiters.set(d.id,done);res.once('close',done);});}
   if(res.destroyed)return;const jobs=queues.get(d.id)||[];queues.set(d.id,[]);return json(res,200,{jobs:jobs.filter(j=>pending.has(j.id))});
  }
  if(match[2]==='result'&&req.method==='POST'){
   const b=JSON.parse((await bytes(req)).toString()),job=pending.get(b.id);if(!job||job.deviceId!==d.id)return json(res,410,{error:'请求已结束'});
   if(!Number.isInteger(b.status)||b.status<100||b.status>599||typeof b.body!=='string')return json(res,400,{error:'响应无效'});
   pending.delete(b.id);clearTimeout(job.timer);if(!job.res.destroyed){job.res.writeHead(b.status,{'content-type':String(b.contentType||'application/json'),'cache-control':'no-store'});job.res.end(Buffer.from(b.body,'base64'));}return json(res,200,{ok:true});
  }
 }
 const target=url.pathname.match(/^\/d\/([a-f0-9-]{36})(\/api\/.*)$/);
 if(target){const d=devices.find(d=>d.id===target[1]);if(!d||hash(req.headers.authorization?.replace(/^Bearer /,''))!==d.phoneTokenHash)return json(res,401,{error:'配对令牌无效'});
  if(!['GET','POST','DELETE'].includes(req.method))return json(res,405,{error:'不支持此方法'});
  const q=queues.get(d.id)||[];if(q.length>=16||[...pending.values()].filter(j=>j.deviceId===d.id).length>=24)return json(res,429,{error:'电脑请求过多，请稍后重试'});
  const id=crypto.randomUUID(),body=await bytes(req,5*1024*1024);const job={id,path:target[2]+url.search,method:req.method,authorization:req.headers.authorization,contentType:req.headers['content-type']||'application/json',body:body.toString('base64')};
  const timer=setTimeout(()=>{pending.delete(id);if(!res.destroyed)json(res,504,{error:'电脑暂时不可达，请确认电脑开机且连接服务运行中'});},45000);pending.set(id,{deviceId:d.id,res,timer});res.on('close',()=>{pending.delete(id);clearTimeout(timer);});q.push(job);queues.set(d.id,q);waiters.get(d.id)?.();return;
 }
 json(res,404,{error:'接口不存在'});
}catch(e){if(!res.headersSent)json(res,e.status||500,{error:'中转请求未完成'});else res.destroy();}});
server.listen(Number(process.env.PORT||48723),'127.0.0.1',()=>console.log(JSON.stringify({port:server.address().port})));
