# Original implementation. Windows PowerShell 5.1 and PowerShell 7.
# Copies only absent local session metadata. No installer, scheduler, group DB,
# credential access, network calls, transcript writes, or deletion propagation.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [ValidateSet('Inspect', 'Preview', 'Apply')][string]$Mode = 'Inspect',
    [string]$SessionRoot,
    [string[]]$Scopes,
    [string]$TranscriptRoot = (Join-Path $env:USERPROFILE '.claude\projects'),
    [string]$BackupRoot
)
$ErrorActionPreference = 'Stop'
$version = '1.0.0'

# A strict, dependency-free JSON reader is used because ConvertFrom-Json differs
# across PS editions (comments, duplicate keys, dates, depth). Original bytes are
# always preserved; this parser is used only for validation and schema checks.
if (-not ('SafeClaudeSessions.Json' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
namespace SafeClaudeSessions {
 public sealed class Json {
  string s; int i;
  Json(string value) { s=value; }
  void Ws() { while(i<s.Length && (s[i]==' '||s[i]=='\t'||s[i]=='\r'||s[i]=='\n')) i++; }
  Exception Bad() { return new FormatException("Invalid or ambiguous JSON at character "+i); }
  char Peek() { if(i>=s.Length) throw Bad(); return s[i]; }
  string Str() {
   if(Peek()!='"') throw Bad(); i++; var b=new StringBuilder(); bool end=false;
   while(i<s.Length) {
    char c=s[i++]; if(c=='"') { end=true; break; }
    if(c<32) throw Bad();
    if(c=='\\') {
     c=Peek(); i++;
     switch(c) {
      case '"': case '\\': case '/': b.Append(c); break;
      case 'b': b.Append('\b'); break; case 'f': b.Append('\f'); break;
      case 'n': b.Append('\n'); break; case 'r': b.Append('\r'); break;
      case 't': b.Append('\t'); break;
      case 'u':
       if(i+4>s.Length) throw Bad(); int n=0;
       for(int k=0;k<4;k++) { char h=s[i++]; int d=h>='0'&&h<='9'?h-'0':h>='a'&&h<='f'?h-'a'+10:h>='A'&&h<='F'?h-'A'+10:-1; if(d<0) throw Bad(); n=n*16+d; }
       b.Append((char)n); break;
      default: throw Bad();
     }
    } else b.Append(c);
   }
   if(!end) throw Bad(); string result=b.ToString();
   for(int j=0;j<result.Length;j++) {
    if(char.IsHighSurrogate(result[j])) { if(j+1>=result.Length||!char.IsLowSurrogate(result[j+1])) throw Bad(); j++; }
    else if(char.IsLowSurrogate(result[j])) throw Bad();
   }
   return result;
  }
  object Value(int depth) {
   if(depth>64) throw Bad(); Ws(); char c=Peek();
   if(c=='{') {
    i++; Ws(); var o=new Dictionary<string,object>(StringComparer.Ordinal);
    if(Peek()=='}') { i++; return o; }
    while(true) {
     Ws(); string k=Str(); if(o.ContainsKey(k)) throw Bad(); Ws(); if(Peek()!=':') throw Bad(); i++;
     o.Add(k,Value(depth+1)); Ws(); c=Peek(); i++; if(c=='}') return o; if(c!=',') throw Bad();
    }
   }
   if(c=='[') {
    i++; Ws(); var a=new List<object>(); if(Peek()==']') { i++; return a; }
    while(true) { a.Add(Value(depth+1)); Ws(); c=Peek(); i++; if(c==']') return a; if(c!=',') throw Bad(); }
   }
   if(c=='"') return Str();
   foreach(string literal in new string[]{"true","false","null"}) {
    if(s.Length-i>=literal.Length && String.CompareOrdinal(s,i,literal,0,literal.Length)==0) { i+=literal.Length; return literal=="null"?null:(object)(literal=="true"); }
   }
   int start=i; if(c=='-') { i++; c=Peek(); }
   if(c=='0') i++;
   else { if(c<'1'||c>'9') throw Bad(); do { i++; } while(i<s.Length&&s[i]>='0'&&s[i]<='9'); }
   if(i<s.Length&&s[i]=='.') { i++; if(Peek()<'0'||Peek()>'9') throw Bad(); do { i++; } while(i<s.Length&&s[i]>='0'&&s[i]<='9'); }
   if(i<s.Length&&(s[i]=='e'||s[i]=='E')) { i++; if(Peek()=='+'||Peek()=='-') i++; if(Peek()<'0'||Peek()>'9') throw Bad(); do { i++; } while(i<s.Length&&s[i]>='0'&&s[i]<='9'); }
   return new NumberToken(s.Substring(start,i-start));
  }
  sealed class NumberToken { public string Text; public NumberToken(string t) { Text=t; } }
  public static Dictionary<string,object> Parse(byte[] bytes) {
   if(bytes==null||bytes.Length==0||bytes.Length>4194304) throw new FormatException("Metadata size outside 1..4194304 bytes");
   string text=new UTF8Encoding(false,true).GetString(bytes); if(text.Length>0&&text[0]=='\uFEFF') text=text.Substring(1);
   var p=new Json(text); object root=p.Value(0); p.Ws();
   if(p.i!=text.Length || !(root is Dictionary<string,object>)) throw p.Bad();
   return (Dictionary<string,object>)root;
  }
  public static byte[] ReadSnapshot(string file) {
   // Deny concurrent writers/deleters for the entire read, not just a timestamp test.
   using(var f=new FileStream(file,FileMode.Open,FileAccess.Read,FileShare.Read)) {
    if(f.Length<1||f.Length>4194304) throw new IOException("Metadata size outside limits");
    byte[] b=new byte[(int)f.Length]; int n=0;
    while(n<b.Length) { int k=f.Read(b,n,b.Length-n); if(k==0) throw new IOException("Short read"); n+=k; }
    if(f.ReadByte()!=-1) throw new IOException("File grew during read"); return b;
   }
  }
  public static void WriteNew(string file, byte[] bytes) {
   using(var f=new FileStream(file,FileMode.CreateNew,FileAccess.Write,FileShare.None)) { f.Write(bytes,0,bytes.Length); f.Flush(true); }
  }
 }
}
'@
}

function Get-SafeFullPath([string]$Path) {
    if (-not $Path -or -not [IO.Path]::IsPathRooted($Path) -or $Path -match '^[\\]{2}' -or $Path -match '^\\\?') {
        throw 'Use an absolute local drive path, not a network or device path.'
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')) { throw 'Unsupported path or alternate data stream.' }
    return $full
}
function Assert-SafePath([string]$Path) {
    $cursor = Get-SafeFullPath $Path
    while ($cursor) {
        if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) {
            if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Link/junction refused: $cursor" }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        $cursor = if ($parent) { $parent.FullName } else { $null }
    }
}
function Test-SafeWithin([string]$Child, [string]$Parent) {
    return $Child.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or $Child.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Get-SafeHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Test-SafeAppRunning {
    foreach ($p in @(Get-Process -Name 'Claude' -ErrorAction SilentlyContinue)) {
        $path = $null; try { $path = $p.Path } catch { }
        if (-not $path -or $path -notmatch '\\claude-code\\') { return $true }
    }
    return $false
}
function Get-SafeDiscoveredRoots {
    $list = @((Join-Path $env:APPDATA 'Claude\claude-code-sessions'), (Join-Path $env:LOCALAPPDATA 'Claude-3p\claude-code-sessions'))
    $packages = Join-Path $env:LOCALAPPDATA 'Packages'
    if ([IO.Directory]::Exists($packages)) {
        foreach ($pkg in @(Get-ChildItem -LiteralPath $packages -Directory -Filter 'Claude_*')) {
            $list += Join-Path $pkg.FullName 'LocalCache\Roaming\Claude\claude-code-sessions'
        }
    }
    return @($list | Where-Object { [IO.Directory]::Exists($_) } | Sort-Object -Unique)
}
function Get-SafeScopeList([string]$Root) {
    Assert-SafePath $Root
    $found = @()
    foreach ($acct in @(Get-ChildItem -LiteralPath $Root -Directory)) {
        if ($acct.Name -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { continue }
        Assert-SafePath $acct.FullName
        foreach ($org in @(Get-ChildItem -LiteralPath $acct.FullName -Directory)) {
            if ($org.Name -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { continue }
            Assert-SafePath $org.FullName
            $count = @(Get-ChildItem -LiteralPath $org.FullName -File -Filter 'local_*.json').Count
            $found += [pscustomobject]@{ Scope = $acct.Name + '/' + $org.Name; MetadataFiles = $count }
        }
    }
    return $found
}

if ($Mode -eq 'Inspect') {
    $roots = if ($SessionRoot) { @(Get-SafeFullPath $SessionRoot) } else { @(Get-SafeDiscoveredRoots) }
    $items = foreach ($root in $roots) {
        if (-not [IO.Directory]::Exists($root)) { throw "Session root does not exist: $root" }
        [pscustomobject]@{ SessionRoot = $root; Scopes = @(Get-SafeScopeList $root) }
    }
    return [pscustomobject]@{ Version = $version; Mode = 'Inspect'; Roots = @($items); Writes = 0 }
}
if (-not $SessionRoot -or @($Scopes).Count -lt 2) { throw 'Preview/Apply requires an explicit SessionRoot and at least two account/org Scopes.' }
$root = Get-SafeFullPath $SessionRoot
$transcripts = Get-SafeFullPath $TranscriptRoot
Assert-SafePath $root; Assert-SafePath $transcripts
if (-not [IO.Directory]::Exists($root) -or -not [IO.Directory]::Exists($transcripts)) { throw 'SessionRoot and TranscriptRoot must already exist.' }
$guidPattern = '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
$scopePattern = '^' + $guidPattern + '/' + $guidPattern + '$'
$targets = @(); $accounts = @{}; $scopeSet = @{}
foreach ($scope in $Scopes) {
    if ($scope -notmatch $scopePattern) { throw "Invalid account/org scope: $scope" }
    if ($scopeSet.ContainsKey($scope)) { throw 'Duplicate scope.' }
    $scopeSet[$scope] = $true
    $acct = ($scope -split '/')[0]
    if ($accounts.ContainsKey($acct)) { throw 'Choose only one organization per account in one run.' }
    $accounts[$acct] = $true
    $path = Get-SafeFullPath (Join-Path $root ($scope.Replace('/', '\')))
    if (-not (Test-SafeWithin $path $root) -or -not [IO.Directory]::Exists($path)) { throw "Scope must already exist: $scope" }
    Assert-SafePath $path
    $targets += [pscustomobject]@{ Scope = $scope; Path = $path }
}
$appRunning = Test-SafeAppRunning
$preview = $Mode -ne 'Apply' -or $WhatIfPreference
if (-not $preview -and $appRunning) { throw 'Close Claude Desktop completely before Apply. No changes were made.' }
$backup = $null
if (-not $preview) {
    if (-not $BackupRoot) { throw 'Apply requires an explicit BackupRoot outside Claude data.' }
    $backup = Get-SafeFullPath $BackupRoot; Assert-SafePath $backup
    $claudeParent = [IO.Directory]::GetParent($root).FullName
    $transcriptParent = [IO.Directory]::GetParent($transcripts).FullName
    if ((Test-SafeWithin $backup $claudeParent) -or (Test-SafeWithin $backup $transcriptParent)) { throw 'Backups must be outside Claude application/config data.' }
    if ([IO.Path]::GetPathRoot($backup) -ine [IO.Path]::GetPathRoot($root)) { throw 'BackupRoot must be on the same local drive for atomic publication.' }
}

# Only transcript paths are indexed; transcript content is not read or changed.
$transcriptIds = @{}
foreach ($project in @(Get-ChildItem -LiteralPath $transcripts -Directory)) {
    Assert-SafePath $project.FullName
    foreach ($f in @(Get-ChildItem -LiteralPath $project.FullName -File -Filter '*.jsonl')) {
        if ($f.BaseName -match ('^' + $guidPattern + '$') -and $f.Length -gt 0 -and ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            $transcriptIds[$f.BaseName] = $true
        }
    }
}
$issues = New-Object System.Collections.Generic.List[object]
$groups = @{}; $existingCount = 0
foreach ($target in $targets) {
    foreach ($file in @(Get-ChildItem -LiteralPath $target.Path -File -Filter 'local_*.json')) {
        $existingCount++
        if ($file.Name -notmatch '^local_[A-Za-z0-9][A-Za-z0-9_-]{0,159}\.json$') {
            $issues.Add([pscustomobject]@{ Scope = $target.Scope; File = $file.Name; Reason = 'Unsupported filename' }); continue
        }
        if (-not $groups.ContainsKey($file.Name)) { $groups[$file.Name] = New-Object System.Collections.Generic.List[object] }
        $candidate = [pscustomobject]@{ Scope = $target.Scope; Path = $file.FullName; Bytes = $null; Hash = $null; Valid = $false }
        $groups[$file.Name].Add($candidate)
        try {
            Assert-SafePath $file.FullName
            $bytes = [SafeClaudeSessions.Json]::ReadSnapshot($file.FullName)
            $doc = [SafeClaudeSessions.Json]::Parse($bytes)
            if (-not $doc.ContainsKey('cliSessionId') -or -not ($doc['cliSessionId'] -is [string]) -or $doc['cliSessionId'] -notmatch ('^' + $guidPattern + '$')) { throw 'Missing or invalid cliSessionId' }
            if ($doc.ContainsKey('transcriptUnavailable') -and (-not ($doc['transcriptUnavailable'] -is [bool]) -or $doc['transcriptUnavailable'])) { throw 'Transcript flagged unavailable or invalid flag' }
            if (-not $transcriptIds.ContainsKey($doc['cliSessionId'])) { throw 'Local transcript missing, empty, or unsafe' }
            if (-not $doc.ContainsKey('cwd') -or -not ($doc['cwd'] -is [string]) -or -not [IO.Path]::IsPathRooted($doc['cwd'])) { throw 'Missing or invalid absolute cwd' }
            if ($doc.ContainsKey('sessionId') -and $doc['sessionId'] -cne $file.BaseName) { throw 'sessionId does not match metadata filename' }
            $candidate.Bytes = $bytes; $candidate.Hash = Get-SafeHash $bytes; $candidate.Valid = $true
        } catch {
            # Do not log JSON content, conversation titles, credentials or exceptions containing input.
            $issues.Add([pscustomobject]@{ Scope = $target.Scope; File = $file.Name; Reason = 'Unreadable, invalid, unsafe, or missing local transcript' })
        }
    }
}
$plans = New-Object System.Collections.Generic.List[object]
foreach ($name in @($groups.Keys | Sort-Object)) {
    $copies = @($groups[$name].ToArray())
    $bad = @($copies | Where-Object { -not $_.Valid })
    $hashes = @($copies | Where-Object Valid | Select-Object -ExpandProperty Hash -Unique)
    if ($bad.Count -gt 0 -or $hashes.Count -ne 1) {
        $issues.Add([pscustomobject]@{ Scope = '*'; File = $name; Reason = 'Conflict or invalid copy: no propagation for this name' }); continue
    }
    $source = $copies[0]
    foreach ($target in $targets) {
        $dest = Join-Path $target.Path $name
        if ([IO.File]::Exists($dest) -or [IO.Directory]::Exists($dest)) { continue }
        $plans.Add([pscustomobject]@{ File = $name; SourceScope = $source.Scope; TargetScope = $target.Scope; Destination = $dest; Hash = $source.Hash; Bytes = $source.Bytes })
    }
}
$added = New-Object System.Collections.Generic.List[object]
$races = New-Object System.Collections.Generic.List[object]
$runDir = $null; $guard = $null
try {
    if (-not $preview -and $plans.Count -gt 0) {
        [void][IO.Directory]::CreateDirectory($backup)
        Assert-SafePath $backup
        # Denies a second writer sharing this backup location. Publication also uses
        # a no-overwrite operation, protecting destinations even across backup roots.
        $guard = [IO.File]::Open((Join-Path $backup '.safe-sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        $runDir = Join-Path $backup ('run-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($runDir)
        $manifest = @($plans | ForEach-Object { [pscustomobject]@{ File = $_.File; SourceScope = $_.SourceScope; TargetScope = $_.TargetScope; SHA256 = $_.Hash } })
        $manifestBytes = [Text.UTF8Encoding]::new($false).GetBytes(($manifest | ConvertTo-Json -Depth 6))
        [SafeClaudeSessions.Json]::WriteNew((Join-Path $runDir 'manifest.json'), $manifestBytes)
        foreach ($hash in @($plans | Select-Object -ExpandProperty Hash -Unique)) {
            $first = $plans | Where-Object { $_.Hash -eq $hash } | Select-Object -First 1
            $saved = Join-Path $runDir ($hash + '.json')
            [SafeClaudeSessions.Json]::WriteNew($saved, $first.Bytes)
            if ((Get-SafeHash ([SafeClaudeSessions.Json]::ReadSnapshot($saved))) -cne $hash) { throw 'Backup verification failed; publication aborted.' }
        }
        foreach ($plan in $plans) {
            if (-not $PSCmdlet.ShouldProcess($plan.Destination, 'Add absent session metadata; preserve every existing file')) { continue }
            if (Test-SafeAppRunning) { throw 'Claude Desktop started; further publication stopped. Existing files were preserved.' }
            Assert-SafePath $plan.Destination; Assert-SafePath $runDir
            if ([IO.File]::Exists($plan.Destination) -or [IO.Directory]::Exists($plan.Destination)) {
                $races.Add([pscustomobject]@{ File = $plan.File; Scope = $plan.TargetScope; Reason = 'Destination appeared; preserved' }); continue
            }
            # Stage outside Claude data, on the same drive. File.Move refuses an
            # existing target atomically. Never Move-Item -Force or File.Replace.
            $stage = Join-Path $runDir ('pending-' + [guid]::NewGuid().ToString('N') + '.json')
            [SafeClaudeSessions.Json]::WriteNew($stage, $plan.Bytes)
            try {
                [IO.File]::Move($stage, $plan.Destination)
                $added.Add([pscustomobject]@{ File = $plan.File; Scope = $plan.TargetScope; SHA256 = $plan.Hash })
            } catch [IO.IOException] {
                if ([IO.File]::Exists($plan.Destination) -or [IO.Directory]::Exists($plan.Destination)) {
                    $races.Add([pscustomobject]@{ File = $plan.File; Scope = $plan.TargetScope; Reason = 'Concurrent creation; destination preserved, staging retained in backup' })
                } else { throw }
            }
        }
    }
} finally { if ($guard) { $guard.Dispose() } }
$publicPlan = @($plans | ForEach-Object { [pscustomobject]@{ File = $_.File; SourceScope = $_.SourceScope; TargetScope = $_.TargetScope; SHA256 = $_.Hash } })
[pscustomobject]@{
    Version = $version; Mode = $(if ($preview) { 'Preview' } else { 'Apply' }); AppRunning = $appRunning
    ExistingMetadataFiles = $existingCount; PlannedAdds = $plans.Count; AddedCount = $added.Count
    ReplacedCount = 0; DeletedCount = 0; BackupDirectory = $runDir
    Plan = $publicPlan; Added = @($added.ToArray()); Issues = @($issues.ToArray()); ConcurrentSkips = @($races.ToArray())
}
