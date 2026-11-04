# 把 index.html 里 LINES 的语音鼓励台词用 Azure 生成 mp3，放在 voice 文件夹（文件名 = 语言-文本哈希.mp3）。
# 带 {d}（米数）、{c}（金币）的台词按游戏里的里程碑展开；已经生成过的不会重复生成，台词删掉后多余的 mp3 会被清理。
# 用法：powershell -ExecutionPolicy Bypass -File tools\make-voice.ps1
. "$PSScriptRoot\azure-tts.ps1"
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'voice'
New-Item -ItemType Directory -Force $out | Out-Null

$Voices = @{
  zh = @{ voice = 'zh-CN-XiaoxiaoNeural'; style = 'cheerful'; lang = 'zh-CN'; rate = '0%' }   # 中文：晓晓，开心的语气
  en = @{ voice = 'en-US-JennyNeural'; style = 'excited'; lang = 'en-US'; rate = '-5%' }      # 英文：Jenny，兴奋的语气（和 moon-english 的夸奖同一个声音）
}
# 和 cheerTick 一致：里程 100/250/500 后每 500 米（生成到 10000 米），金币 50/100 后每 100（生成到 1000）；超出范围的游戏里用设备语音
$Dists = @(100, 250) + (1..20 | ForEach-Object { $_ * 500 })
$Coins = @(50) + (1..10 | ForEach-Object { $_ * 100 })

# 文件名里的哈希：FNV-1a 32 位（和网页里的 fnv() 完全一样）
function Get-Fnv([string]$s) {
  [uint64]$h = 2166136261
  foreach ($c in $s.ToCharArray()) { $h = $h -bxor [uint64][int]$c; $h = ($h * 16777619) % 4294967296 }
  '{0:x8}' -f $h
}

# ---------- 从 index.html 读出 LINES（语音鼓励）和 LEARN（学习短句，语速放慢，方便小朋友跟读） ----------
$html = [IO.File]::ReadAllText((Join-Path $root 'index.html'), [Text.Encoding]::UTF8)
$want = @{}
$Sets = @(
  @{ name = 'LINES'; rate = @{ zh = '0%'; en = '-5%' } },
  @{ name = 'LEARN'; rate = @{ zh = '-8%'; en = '-15%' } }
)
foreach ($set in $Sets) {
if ($html -notmatch "(?s)const $($set.name)=\{(.+?)\};") { throw "$($set.name) not found in index.html" }
# 每一对是 ['中文','English']，两边都可以用单引号或双引号（英文里有 ' 时用双引号）
$body = $Matches[1]
$found = [regex]::Matches($body, "\[(?:'([^']*)'|""([^""]*)""),\s*(?:""([^""]*)""|'([^']*)')\]")
$total = [regex]::Matches($body, "\[\s*['""]").Count
if ($found.Count -ne $total) { throw "$($set.name): only $($found.Count) of $total pairs parsed - check the quotes" }
foreach ($m in $found) {
  $pair = @{ zh = $(if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }); en = $(if ($m.Groups[3].Success) { $m.Groups[3].Value } else { $m.Groups[4].Value }) }
  foreach ($lang in 'zh', 'en') {
    $t = $pair[$lang]
    $texts = if ($t.Contains('{d}')) { $Dists | ForEach-Object { $t.Replace('{d}', "$_") } }
             elseif ($t.Contains('{c}')) { $Coins | ForEach-Object { $t.Replace('{c}', "$_") } }
             else { @($t) }
    foreach ($x in $texts) { $want["$lang-$(Get-Fnv $x)"] = @{ text = $x; lang = $lang; rate = $set.rate[$lang] } }
  }
}
}
Write-Host "clips: $($want.Count)"

# ---------- 生成 ----------
$todo = @($want.Keys | Where-Object { -not (Test-Path (Join-Path $out "$_.mp3")) })
Write-Host "to generate: $($todo.Count)"
$n = 0; $failed = 0
foreach ($k in $todo) {
  $w = $want[$k]; $v = $Voices[$w.lang]; $n++
  $ok = Invoke-Tts -Text $w.text -Voice $v.voice -Style $v.style -Lang $v.lang -Rate $w.rate -OutFile (Join-Path $out "$k.mp3")
  if (-not $ok) { $failed++ }
  if ($n % 20 -eq 0) { Write-Host "  $n / $($todo.Count)" }
}
# 清理不再用到的 mp3
foreach ($f in Get-ChildItem $out -Filter *.mp3) { if (-not $want.ContainsKey($f.BaseName)) { Remove-Item $f.FullName; Write-Host "  removed $($f.Name)" } }
Write-Host "done, failed: $failed"
