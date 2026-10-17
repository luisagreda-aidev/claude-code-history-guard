// Fail closed on unexpected files and likely secrets. Never prints matched values.
const fs=require('fs'),path=require('path'),cp=require('child_process');
const root=path.resolve(__dirname,'..');
const policy=JSON.parse(fs.readFileSync(path.join(__dirname,'public-files.json'),'utf8'));
const allowed=new Set(policy.files);
const patterns=[
 ['access-token',/(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}/],
 ['private-key',/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/],
 ['literal-home-path',/(?:[A-Z]:\\Users\\|\/Users\/|\/home\/)[^\s\\/"'<>]+/i],
 ['email-address',/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/],
];
const allowedEmails=new Set(['history-guard@users.noreply.github.com']);
const syntheticIds=new Set(['123e4567-e89b-12d3-a456-426614174000']);
const uuid=/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;
function check(bytes,label){
 if(bytes.length>2*1024*1024||bytes.includes(0))throw Error('Non-text or oversized content: '+label);
 const text=new TextDecoder('utf-8',{fatal:true}).decode(bytes);
 for(const [kind,re]of patterns){const matches=text.match(new RegExp(re.source,re.flags+'g'))||[];for(const m of matches){if(kind==='email-address'&&allowedEmails.has(m))continue;throw Error(kind+' detected in '+label+' (value suppressed)');}}
 for(const id of text.match(uuid)||[]){if(!syntheticIds.has(id.toLowerCase())&&!/^([0-9a-f])\1{7}-\1{4}-\1{4}-\1{4}-\1{12}$/i.test(id))throw Error('Non-synthetic literal UUID in '+label+' (value suppressed)');}
}
function walk(dir){return fs.readdirSync(dir,{withFileTypes:true}).flatMap(e=>{
 if(['.git','artifacts','work','node_modules'].includes(e.name))return[];
 const full=path.join(dir,e.name),rel=path.relative(root,full).split(path.sep).join('/');
 if(e.isSymbolicLink())throw Error('Symlink refused');
 return e.isDirectory()?walk(full):[rel];
});}
try{
 let files;
 const git=cp.spawnSync('git',['ls-files','-z'],{cwd:root,encoding:'utf8'});
 if(git.status===0&&fs.existsSync(path.join(root,'.git')))files=git.stdout.split('\0').filter(Boolean);else files=walk(root);
 for(const file of files){if(!allowed.has(file))throw Error('Unexpected file: '+file);check(fs.readFileSync(path.join(root,file)),file);}
 if(process.argv.includes('--git-history')){
  const objects=cp.execFileSync('git',['rev-list','--objects','--all'],{cwd:root,encoding:'utf8'}).trim().split('\n');
  for(const entry of objects){const [oid,...parts]=entry.split(' ');if(!oid)continue;const type=cp.execFileSync('git',['cat-file','-t',oid],{cwd:root,encoding:'utf8'}).trim();if(type==='blob'){const file=parts.join(' ');if(!allowed.has(file))throw Error('Unexpected historical path');check(cp.execFileSync('git',['cat-file','blob',oid],{cwd:root}),'historical blob');}}
  const commits=cp.execFileSync('git',['log','--all','--format=%B%n%an <%ae>%n%cn <%ce>'],{cwd:root});check(commits,'commit metadata');
 }
 process.stdout.write(JSON.stringify({publicTreeAudit:'passed',files:files.length,historyAudited:process.argv.includes('--git-history')})+'\n');
}catch(e){process.stderr.write(e.message+'\n');process.exitCode=1;}
