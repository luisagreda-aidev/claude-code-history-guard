// Independent read-only verifier. Does not execute or print conversation content.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, ''));
const manifestPath = path.join(config.snapshot, 'manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const digest = async (file) => {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('Non-regular file refused');
  const hash = crypto.createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return {hash:hash.digest('hex'), size:stat.size};
};
const resolve = (root, rel) => {
  const full = path.resolve(root, rel);
  const tail = path.relative(root, full);
  if (tail.startsWith('..') || path.isAbsolute(tail)) throw new Error('Path escaped selected directory');
  return full;
};
(async () => {
  let cursor = 0, verified = 0, bytes = 0;
  const seen = new Set();
  for (const entry of manifest.Files) {
    const key = entry.RelativePath.toLowerCase();
    if (seen.has(key)) throw new Error('Duplicate entry');
    seen.add(key);
  }
  await Promise.all(Array.from({length:4}, async () => {
    for (;;) {
      const index = cursor++;
      if (index >= manifest.Files.length) break;
      const entry = manifest.Files[index];
      const match = /^data\/(projects|sessions)\/(.+)$/.exec(entry.RelativePath);
      if (!match) throw new Error('Unexpected manifest path');
      const files = [resolve(config.snapshot,entry.RelativePath), resolve(config.recovered,entry.RelativePath), resolve(config[match[1]],match[2])];
      for (const file of files) {
        const result = await digest(file);
        if (result.hash !== entry.SHA256 || result.size !== entry.Length) throw new Error('Backup, recovery or original hash mismatch');
      }
      verified++; bytes += entry.Length;
    }
  }));
  if (verified !== manifest.FileCount) throw new Error('Inventory mismatch');
  process.stdout.write(JSON.stringify({IndependentVerifier:'Node.js crypto SHA-256',Verified:true,FilesCompared:verified,BytesComparedPerCopy:bytes,CopiesCompared:3,BackupMatchesManifest:true,RecoveredMatchesManifest:true,OriginalsStillMatchManifest:true,FinishedUtc:new Date().toISOString()},null,2));
})().catch(() => { process.stderr.write('Independent recovery verification failed. No files were modified.\n'); process.exit(1); });
