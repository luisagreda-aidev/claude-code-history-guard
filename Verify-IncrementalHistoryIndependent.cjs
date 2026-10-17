// Independent SHA-256 verifier for the deduplicated format. Read-only.
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const snapshot=path.resolve(process.argv[2]||'');
const restored=process.argv[3]&&path.resolve(process.argv[3]);
const hash=p=>new Promise((resolve,reject)=>{const h=crypto.createHash('sha256'),s=fs.createReadStream(p);s.on('error',reject);s.on('data',b=>h.update(b));s.on('end',()=>resolve(h.digest('hex')));});
(async()=>{
 const manifestPath=path.join(snapshot,'manifest.json');
 const m=JSON.parse(fs.readFileSync(manifestPath,'utf8').replace(/^\uFEFF/,''));
 const c=JSON.parse(fs.readFileSync(path.join(snapshot,'COMPLETE.json'),'utf8').replace(/^\uFEFF/,''));
 if(m.Format!=='ClaudeHistoryDeduplicated-v1'||c.Status!=='Complete'||await hash(manifestPath)!==c.ManifestSHA256)throw Error('Invalid manifest');
 const base=path.dirname(path.dirname(snapshot)),seen=new Set();let n=0,bytes=0;
 for(const e of m.Files){
  if(!/^data\/(projects|sessions)\//.test(e.RelativePath)||/(^|\/)\.{1,2}(\/|$)|[\\:]/.test(e.RelativePath)||!/^[a-f0-9]{64}$/.test(e.SHA256)||seen.has(e.RelativePath))throw Error('Unsafe entry');
  seen.add(e.RelativePath);
 }
 if(seen.size!==m.FileCount||!seen.size)throw Error('Invalid count');
 let cursor=0;await Promise.all(Array.from({length:4},async()=>{
  while(cursor<m.Files.length){const e=m.Files[cursor++],p=path.join(base,'blobs',e.SHA256);
   if(fs.statSync(p).size!==e.Length||await hash(p)!==e.SHA256)throw Error('Blob mismatch');
   if(restored){const r=path.join(restored,...e.RelativePath.split('/'));if(fs.statSync(r).size!==e.Length||await hash(r)!==e.SHA256)throw Error('Restore mismatch');}
   n++;bytes+=e.Length;
  }
 }));
 process.stdout.write(JSON.stringify({Verified:true,IndependentRuntime:'Node.js '+process.version,Files:n,Bytes:bytes,Snapshot:snapshot,RecoveryVerified:!!restored},null,2));
})().catch(e=>{process.stderr.write(e.message);process.exitCode=1;});
