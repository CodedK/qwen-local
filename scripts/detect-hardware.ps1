<#
.SYNOPSIS
    Profiles the machine and picks the right local-Qwen model tier.
.DESCRIPTION
    The binding constraint for local LLMs is almost never raw compute - it is
    (a) how much fits in VRAM and (b) how fast weights that DON'T fit can be
    streamed from system RAM. This script measures both and maps them to a tier.

    Writes hardware-profile.json to the repo root and prints a summary.
.NOTES
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>
[CmdletBinding()]
param(
    [switch]$Quiet,
    # Override if channel auto-detection guesses wrong (see docs/hardware-sizing.md).
    [int]$ForceMemoryChannels = 0
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- GPU --------
$gpu = @{ name = 'none'; vramTotalMB = 0; vramFreeMB = 0; driver = ''; computeCap = '' }
$smi = Get-Command nvidia-smi -ErrorAction Ignore
if ($smi) {
    # nvidia-smi is authoritative. Win32_VideoController.AdapterRAM is a uint32
    # and silently wraps at 4 GB, so it reports "4 GB" for any larger card.
    $q = & nvidia-smi --query-gpu=name,memory.total,memory.free,driver_version,compute_cap --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -eq 0 -and $q) {
        $f = ($q | Select-Object -First 1) -split '\s*,\s*'
        $gpu.name        = $f[0]
        $gpu.vramTotalMB = [int]$f[1]
        $gpu.vramFreeMB  = [int]$f[2]
        $gpu.driver      = $f[3]
        $gpu.computeCap  = $f[4]
    }
} else {
    $vc = Get-CimInstance Win32_VideoController | Select-Object -First 1
    if ($vc) { $gpu.name = $vc.Name }   # AMD/Intel: size left at 0, treat as CPU-only
}

# ---------------------------------------------------------------- CPU --------
$c = Get-CimInstance Win32_Processor | Select-Object -First 1
$cpu = @{
    name    = $c.Name.Trim()
    cores   = [int]$c.NumberOfCores
    threads = [int]$c.NumberOfLogicalProcessors
}

# ---------------------------------------------------------------- RAM --------
$dimms    = @(Get-CimInstance Win32_PhysicalMemory)
$totalRam = [math]::Round(((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB), 1)
$speed    = 0
if ($dimms.Count -gt 0) {
    $speeds = $dimms | ForEach-Object { if ($_.ConfiguredClockSpeed) { [int]$_.ConfiguredClockSpeed } else { [int]$_.Speed } }
    $speed  = ($speeds | Measure-Object -Minimum).Minimum   # slowest stick sets the pace
}

# Channels: infer from DeviceLocator/BankLabel ("ChannelA-DIMM0"). Populated DIMM
# count is NOT channel count - consumer boards run 4 sticks on 2 channels.
$channels = 0
if ($ForceMemoryChannels -gt 0) {
    $channels = $ForceMemoryChannels
} else {
    $labels = $dimms | ForEach-Object { "$($_.DeviceLocator) $($_.BankLabel)" }
    $found  = $labels | Select-String -Pattern 'Channel\s*([A-H])' -AllMatches |
              ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } |
              Select-Object -Unique
    if ($found -and $found.Count -gt 0) {
        $channels = $found.Count
    } else {
        # Fall back on platform shape: HEDT/server boards expose many slots.
        $slots = (Get-CimInstance Win32_PhysicalMemoryArray | Select-Object -First 1).MemoryDevices
        if ($slots -ge 8)    { $channels = 4 }
        elseif ($slots -ge 4){ $channels = 2 }
        else                 { $channels = [math]::Max(1, [math]::Min($dimms.Count, 2)) }
    }
}

# Theoretical peak = channels * MT/s * 8 bytes. Real sustained read is ~75%.
$peakBw = [math]::Round(($channels * $speed * 8) / 1000, 1)
$realBw = [math]::Round($peakBw * 0.75, 1)

$ram = @{
    totalGB        = $totalRam
    dimms          = $dimms.Count
    speedMTs       = $speed
    channels       = $channels
    peakBandwidth  = $peakBw
    usableBandwidth= $realBw
}

# --------------------------------------------------------------- DISK --------
$sysDrive = ($env:SystemDrive)
$d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sysDrive'"
$disk = @{ drive = $sysDrive; freeGB = [math]::Round($d.FreeSpace/1GB,1); totalGB = [math]::Round($d.Size/1GB,1) }

# --------------------------------------------------------------- TIER --------
# Reserve headroom for the desktop compositor, browsers and the KV cache.
$reserveMB  = 1536
$usableVram = [math]::Max(0, $gpu.vramTotalMB - $reserveMB)
$usableGB   = [math]::Round($usableVram / 1024, 1)

# Tier is driven by what fits on the GPU. RAM only gates the MoE hybrid path.
$tiers = @(
    @{ id='cpu-only'; maxGB=1.0  }
    @{ id='vram-6';   maxGB=6.0  }
    @{ id='vram-10';  maxGB=10.0 }
    @{ id='vram-14';  maxGB=14.0 }
    @{ id='vram-20';  maxGB=20.0 }
    @{ id='vram-32';  maxGB=32.0 }
    @{ id='vram-64';  maxGB=64.0 }
    @{ id='vram-max'; maxGB=[double]::MaxValue }
)
$tier = ($tiers | Where-Object { $usableGB -le $_.maxGB } | Select-Object -First 1).id

# Model recommendations per tier. Names are Ollama refs; hf.co/... pulls straight
# from Hugging Face. See docs/model-catalog.md for verified sizes.
$U9  = 'hf.co/mradermacher/Qwen3.8-9B-heretic-uncensored-GGUF'
$U27 = 'hf.co/JonathanColetti/Qwen3.8-27B-Uncensored-GGUF'

$plans = @{
    'cpu-only' = @{ agent='qwen3.5:4b';        uncensored="${U9}:Q4_K_S";        autocomplete='qwen2.5-coder:1.5b-base' }
    'vram-6'   = @{ agent='qwen3-coder:30b';   uncensored="${U9}:IQ4_XS";        autocomplete='qwen2.5-coder:1.5b-base' }
    'vram-10'  = @{ agent='qwen3-coder:30b';   uncensored="${U9}:Q4_K_M";        autocomplete='qwen2.5-coder:1.5b-base' }
    'vram-14'  = @{ agent='qwen3-coder:30b';   uncensored="${U27}:noMTP-IQ2_M";  autocomplete='qwen2.5-coder:3b-base'   }
    'vram-20'  = @{ agent='qwen3-coder:30b';   uncensored="${U27}:noMTP-IQ4_XS"; autocomplete='qwen2.5-coder:3b-base'   }
    'vram-32'  = @{ agent='qwen3-coder:30b';   uncensored="${U27}:noMTP-Q4_K_M"; autocomplete='qwen2.5-coder:3b-base'   }
    'vram-64'  = @{ agent='qwen3-coder-next';  uncensored="${U27}:noMTP-Q6_K";   autocomplete='qwen2.5-coder:3b-base'   }
    'vram-max' = @{ agent='qwen3-coder-next:q8_0'; uncensored="${U27}:noMTP-Q8_0"; autocomplete='qwen2.5-coder:3b-base' }
}
$plan = $plans[$tier]

# qwen3-coder-next is 52 GB at Q4 - only sane with lots of system RAM to spare.
$notes = New-Object System.Collections.Generic.List[string]
if ($plan.agent -like 'qwen3-coder-next*' -and $ram.totalGB -lt 64) {
    $plan.agent = 'qwen3-coder:30b'
    $notes.Add("Downgraded agent to qwen3-coder:30b - qwen3-coder-next needs >=64 GB RAM, found $($ram.totalGB) GB.")
}
if ($realBw -gt 0 -and $realBw -lt 40) {
    $notes.Add("RAM bandwidth ~$realBw GB/s is low. Dense models that spill out of VRAM will be very slow; prefer MoE (A3B) models.")
}
if ($disk.freeGB -lt 60) {
    $notes.Add("Only $($disk.freeGB) GB free on $sysDrive - the full model set needs ~45 GB.")
}
if ($gpu.vramTotalMB -eq 0) {
    $notes.Add('No NVIDIA GPU detected: everything runs on CPU. Expect single-digit tokens/sec.')
}

# -------------------------------------------------------------- OUTPUT -------
$hwProfile = [ordered]@{
    generatedAt = (Get-Date).ToString('s')
    machine     = $env:COMPUTERNAME
    gpu         = $gpu
    cpu         = $cpu
    ram         = $ram
    disk        = $disk
    tier        = $tier
    usableVramGB= $usableGB
    recommended = $plan
    notes       = $notes
}

$outPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'hardware-profile.json'
$hwProfile | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath -Encoding UTF8

if (-not $Quiet) {
    Write-Host ""
    Write-Host "  Hardware profile - $($env:COMPUTERNAME)" -ForegroundColor Cyan
    Write-Host "  ----------------------------------------------------------"
    Write-Host ("  GPU        : {0}" -f $gpu.name)
    Write-Host ("  VRAM       : {0} MB total / {1} MB free  -> {2} GB usable" -f $gpu.vramTotalMB, $gpu.vramFreeMB, $usableGB)
    Write-Host ("  CPU        : {0} ({1}c/{2}t)" -f $cpu.name, $cpu.cores, $cpu.threads)
    Write-Host ("  RAM        : {0} GB, {1} x DIMM @ {2} MT/s, {3} channel(s)" -f $ram.totalGB, $ram.dimms, $ram.speedMTs, $ram.channels)
    Write-Host ("  Bandwidth  : ~{0} GB/s peak, ~{1} GB/s usable" -f $peakBw, $realBw)
    Write-Host ("  Disk       : {0} GB free on {1}" -f $disk.freeGB, $disk.drive)
    Write-Host ""
    Write-Host ("  TIER       : {0}" -f $tier) -ForegroundColor Green
    Write-Host ("  agent        -> {0}" -f $plan.agent)
    Write-Host ("  uncensored   -> {0}" -f $plan.uncensored)
    Write-Host ("  autocomplete -> {0}" -f $plan.autocomplete)
    if ($notes.Count -gt 0) {
        Write-Host ""
        foreach ($n in $notes) { Write-Host "  ! $n" -ForegroundColor Yellow }
    }
    Write-Host ""
    Write-Host "  Saved to $outPath" -ForegroundColor DarkGray
    Write-Host ""
}

return $hwProfile
