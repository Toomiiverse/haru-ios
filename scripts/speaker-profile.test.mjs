import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const calls=[];
const snapshot={enrolled:true,validated:true,enabled:false,deferVoiceStart:false,message:'Ready'};
const server=createServer(async(req,res)=>{
 try {
  const chunks=[];for await(const c of req)chunks.push(c);const body=Buffer.concat(chunks);
  calls.push(req.url);
  if(req.url==='/api/speaker/enroll'){
   assert.equal(req.headers['content-type'],'audio/wav');assert.equal(body.length,256044);assert.equal(body.toString('ascii',0,4),'RIFF');
  }else if(req.method==='POST'){
   assert.match(req.headers['content-type'],/application\/json/);assert.deepEqual(JSON.parse(body.toString()),{});
  }
  res.setHeader('content-type','application/json');
  if(req.url==='/api/speaker/forget'){res.writeHead(401);res.end('{"error":"Sign in"}');return;}
  res.end(JSON.stringify({...snapshot,enabled:req.url==='/api/speaker/enable'}));
 }catch(e){process.exitCode=1;res.writeHead(500);res.end(JSON.stringify({error:e.message}));console.error(e);}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
try{
 const child=spawn(process.argv[2],[`http://127.0.0.1:${server.address().port}`],{stdio:'inherit'});
 const code=await new Promise(r=>child.on('exit',r));assert.equal(code,0);
 assert.deepEqual(calls,['/api/speaker/status','/api/speaker/enroll','/api/speaker/enable','/api/speaker/forget']);
 const source=readFileSync('Haru/Sources/State/ChatStore.swift','utf8');
 const raw=source.slice(source.indexOf('audio.onVoiceStart ='),source.indexOf('audio.onVoiceEnd ='));
 assert.ok(!raw.includes('voiceStarted('),'Unverified raw speech interrupts playback');
 const hear=source.slice(source.indexOf('private func hear('),source.indexOf('private func act('));
 assert.ok(hear.indexOf('talk === activeTalk')<hear.indexOf('say(line,'));
 assert.ok(hear.indexOf('!text.isEmpty')<hear.indexOf('talk.voiceStarted(now)'));
 assert.ok(!hear.includes('entries.append'));
 console.log('Native speech wiring: rejected audio cannot interrupt or enter history; stale dictation dropped.');
}finally{server.close();}
