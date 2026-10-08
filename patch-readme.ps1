# patch-readme.ps1 - insert new diagnostic + probe into the file tree
$f = 'C:\therock\rocm-dual-gpu-kit\README.md'
$content = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)

# We need to insert inside the code block, right after the validate.ps1 line.
# The block ends with a backtick-fence ```` `` line. We anchor on the validate
# line + the immediately following blank line + code-block closer.
$validate = [char]0x2514 + [char]0x2500 + [char]0x2500 + ' validate.ps1               <- Phase 5: end-to-end smoke test'
$fence    = '```'                                              # closing fence
$new1     = [char]0x2514 + [char]0x2500 + [char]0x2500 + ' diagnose-connection.ps1    <- Phase 5.5: read-only transport diagnostic (auto-invoked by validate.ps1 on dGPU failure)'
$new2     = [char]0x2514 + [char]0x2500 + [char]0x2500 + ' dgpu-probe.ps1             <- optional: finer-grained PnP probe'

# Old = validate line + newline + (optional blank line) + fence.
# Be flexible: try with a blank line first; if not found, try without.
$oldWithBlank    = $validate + [Environment]::NewLine + [Environment]::NewLine + $fence
$oldWithoutBlank = $validate + [Environment]::NewLine + $fence

$old = $null
if ($content.Contains($oldWithBlank))    { $old = $oldWithBlank }
elseif ($content.Contains($oldWithoutBlank)) { $old = $oldWithoutBlank }
else {
    Write-Host "could not anchor on validate.ps1 + fence"
    Write-Host "first 200 bytes around validate:"
    $idx = $content.IndexOf($validate)
    if ($idx -ge 0) {
        Write-Host ($content.Substring($idx, [Math]::Min(400, $content.Length - $idx)))
    }
    exit 1
}

$new = $validate + [Environment]::NewLine + $new1 + [Environment]::NewLine + $new2 + [Environment]::NewLine + [Environment]::NewLine + $fence

$count = ([regex]::Matches($content, [regex]::Escape($old))).Count
Write-Host "matches: $count"
if ($count -ne 1) { exit 1 }

$patched = $content -replace [regex]::Escape($old), $new
[System.IO.File]::WriteAllText($f, $patched, (New-Object System.Text.UTF8Encoding $false))
Write-Host "patched. new size: $($patched.Length)"
