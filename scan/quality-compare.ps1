# Quality spot-check: Strata IQ2_XS vs Ollama q4_K_M on the same prompts.
# Same methodology as the speed harness: fresh seeded prompts, deterministic
# settings (temperature 0), identical prompt set for both endpoints.
# Output: quality-compare-<ts>\answers.md + answers.json
param(
    [string]$StrataBase = 'http://127.0.0.1:8080',
    [string]$OllamaBase = 'http://127.0.0.1:11434',
    [string]$OllamaModel = 'qwen3.8-flash-next:125b-a6b-q4_K_M',
    [string]$StrataModel = 'strata',
    [int]$MaxTokens = 512,
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot "results\quality-compare-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Prompt set: mix of reasoning, factual recall, code, and instruction-following.
# Deterministic (temperature 0) so quant differences show up as content diffs.
$prompts = @(
    @{ id = 'reasoning-1'; text = 'A farmer has 17 sheep. All but 9 die. How many sheep does the farmer have left? Explain your reasoning in one sentence.' },
    @{ id = 'reasoning-2'; text = 'If it takes 5 machines 5 minutes to make 5 widgets, how long would it take 100 machines to make 100 widgets? Show your work briefly.' },
    @{ id = 'factual-1';   text = 'What year did the Berlin Wall fall, and which two German states were reunified as a result? Answer in two sentences.' },
    @{ id = 'factual-2';   text = 'Name the four largest planets in our solar system in order of size, largest first. One line.' },
    @{ id = 'code-1';      text = 'Write a Python function that returns the nth Fibonacci number using memoization. Include a one-line docstring. Code only, no explanation.' },
    @{ id = 'code-2';      text = 'What does this Python snippet print? Answer with just the output.\n\nx = [1, 2, 3]\ny = x\ny.append(4)\nprint(len(x))' },
    @{ id = 'instruct-1';  text = 'Summarize the plot of Romeo and Juliet in exactly three sentences. No more, no less.' },
    @{ id = 'instruct-2';  text = 'Translate to French: "The weather is beautiful today, let us go for a walk in the park." Output only the translation.' },
    @{ id = 'math-1';      text = 'What is 15% of 240? Show the calculation in one line.' },
    @{ id = 'logic-1';     text = 'All roses are flowers. Some flowers fade quickly. Can we conclude that some roses fade quickly? Answer yes or no, then explain in one sentence.' }
)

function Invoke-Chat {
    param([string]$Base, [string]$Model, [string]$Text, [bool]$IsStrata)
    $body = @{
        model      = $Model
        messages   = @(@{ role = 'user'; content = $Text })
        max_tokens = $MaxTokens
        temperature = 0
        stream     = $false
    }
    if ($IsStrata) { $body['reasoning_effort'] = 'none' }
    $json = $body | ConvertTo-Json -Depth 5
    $t0 = Get-Date
    try {
        $r = Invoke-RestMethod "$Base/v1/chat/completions" -Method Post -ContentType 'application/json' -Body $json -TimeoutSec 900
        $dt = ((Get-Date) - $t0).TotalSeconds
        return @{ ok = $true; content = $r.choices[0].message.content; seconds = [math]::Round($dt, 1) }
    } catch {
        return @{ ok = $false; content = "ERROR: $($_.Exception.Message)"; seconds = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1) }
    }
}

$results = @()
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Quality spot-check: Strata IQ2_XS vs Ollama q4_K_M")
[void]$md.AppendLine("")
[void]$md.AppendLine("- Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
[void]$md.AppendLine("- Strata: $StrataBase (IQ2_XS, KV 8-bit, MTP)")
[void]$md.AppendLine("- Ollama: $OllamaBase ($OllamaModel)")
[void]$md.AppendLine("- Settings: temperature=0, max_tokens=$MaxTokens, identical prompts")
[void]$md.AppendLine("")

foreach ($p in $prompts) {
    Write-Host "[$($p.id)] querying Strata..." -ForegroundColor Cyan
    $s = Invoke-Chat -Base $StrataBase -Model $StrataModel -Text $p.text -IsStrata $true
    Write-Host "[$($p.id)] querying Ollama..." -ForegroundColor Cyan
    $o = Invoke-Chat -Base $OllamaBase -Model $OllamaModel -Text $p.text -IsStrata $false

    $results += [ordered]@{
        id = $p.id
        prompt = $p.text
        strata = $s
        ollama = $o
    }

    [void]$md.AppendLine("## $($p.id)")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("**Prompt:** $($p.text)")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("**Strata IQ2_XS** ($($s.seconds)s):")
    [void]$md.AppendLine("")
    [void]$md.AppendLine('```')
    [void]$md.AppendLine($s.content)
    [void]$md.AppendLine('```')
    [void]$md.AppendLine("")
    [void]$md.AppendLine("**Ollama q4_K_M** ($($o.seconds)s):")
    [void]$md.AppendLine("")
    [void]$md.AppendLine('```')
    [void]$md.AppendLine($o.content)
    [void]$md.AppendLine('```')
    [void]$md.AppendLine("")
    [void]$md.AppendLine("---")
    [void]$md.AppendLine("")
}

$md | Out-File (Join-Path $OutDir 'answers.md') -Encoding utf8
$results | ConvertTo-Json -Depth 6 | Out-File (Join-Path $OutDir 'answers.json') -Encoding utf8
Write-Host "=== done — results in $OutDir ===" -ForegroundColor Green
