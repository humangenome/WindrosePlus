# Tests Remove-TreeNoFollow, the delete generateTiles.ps1 and WindrosePlus-BuildCatalog.ps1 use for their own
# temporary folders: a junction or symbolic link inside the folder, or the folder itself as a link, is removed as a
# link and what it points to stays; with -Root, a link between the root and the folder stops the delete. Both scripts
# carry the same copy of the function, and the catalog builder's own run is checked too.
# Windows (junctions and links).
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-NoFollowDelete.ps1
#      pwsh -File scripts/Test-NoFollowDelete.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = (Get-Process -Id $PID).Path

$failed = 0
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "ok   $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert($Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }

function Get-FunctionText([string]$File, [string]$Name) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$File does not parse: $($errors[0].Message)" }
    $found = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $found) { throw "$Name not found in $File" }
    return $found.Extent.Text
}
$tiles = Join-Path $root 'tools\generateTiles.ps1'
$catalog = Join-Path $root 'tools\WindrosePlus-BuildCatalog.ps1'
$copies = @{}
foreach ($file in @($tiles, $catalog)) {
    $copies[$file] = (Get-FunctionText $file 'Remove-TreeNoFollow') + "`n" + (Get-FunctionText $file 'Remove-TreeNoFollowEntry')
}
Case 'generateTiles.ps1 and WindrosePlus-BuildCatalog.ps1 carry the same copy' {
    Assert (($copies[$tiles] -replace "`r", '') -ceq ($copies[$catalog] -replace "`r", '')) 'the two copies differ'
}
. ([scriptblock]::Create($copies[$tiles]))

$base = Join-Path ([System.IO.Path]::GetTempPath()) ("wp-nofollow-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null
$outside = Join-Path $base 'outside'

function New-Outside {
    New-Item -ItemType Directory -Path (Join-Path $outside 'sub') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'keep')
    [System.IO.File]::WriteAllText((Join-Path $outside 'sub\keep2.txt'), 'keep')
}
function Assert-OutsideWhole {
    Assert ((Test-Path -LiteralPath (Join-Path $outside 'keep.txt')) -and (Test-Path -LiteralPath (Join-Path $outside 'sub\keep2.txt'))) 'a file the link pointed to was deleted'
    Assert ([System.IO.File]::ReadAllText((Join-Path $outside 'keep.txt')) -eq 'keep') 'a file the link pointed to was changed'
}
function New-Junction([string]$Path, [string]$Target) { New-Item -ItemType Junction -Path $Path -Value $Target | Out-Null }
function Test-Gone([string]$Path) {
    try { [void][System.IO.File]::GetAttributes($Path); return $false }
    catch { return $true }
}
function Invoke-Catalog([string]$GameDir, [string]$Repak) {
    # Windows PowerShell 5.1 turns a child's stderr into error records; do not stop on them.
    $ErrorActionPreference = 'Continue'
    $out = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $catalog -GameDir $GameDir -Repak $Repak -Force 2>&1 | Out-String
    # Windows PowerShell 5.1 wraps a child's stderr text at the console width: join it back into one line.
    return @{ Code = $LASTEXITCODE; Output = ($out -replace '\s+', ' ') }
}

try {
    New-Outside

    Case 'junctions inside the folder are removed as links, read-only files and folders are deleted' {
        $t = Join-Path $base 'tree1'
        New-Item -ItemType Directory -Path (Join-Path $t 'deep') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $t 'a.txt'), 'a')
        [System.IO.File]::WriteAllText((Join-Path $t 'deep\b.txt'), 'b')
        [System.IO.File]::SetAttributes((Join-Path $t 'deep\b.txt'), [System.IO.FileAttributes]::ReadOnly)
        New-Junction (Join-Path $t 'deep\j') $outside
        New-Junction (Join-Path $t 'j2') (Join-Path $outside 'sub')
        $deep = New-Object System.IO.DirectoryInfo (Join-Path $t 'deep')
        $deep.Attributes = $deep.Attributes -bor [System.IO.FileAttributes]::ReadOnly
        Remove-TreeNoFollow -LiteralPath $t
        Assert (Test-Gone $t) 'the folder is still there'
        Assert-OutsideWhole
    }

    Case 'a folder that is itself a junction: only the link goes' {
        $t = Join-Path $base 'tree2'
        New-Junction $t $outside
        Remove-TreeNoFollow -LiteralPath $t
        Assert (Test-Gone $t) 'the junction is still there'
        Assert-OutsideWhole
    }

    Case 'folder and file symbolic links inside are removed as links' {
        $t = Join-Path $base 'tree3'
        New-Item -ItemType Directory -Path $t -Force | Out-Null
        try {
            New-Item -ItemType SymbolicLink -Path (Join-Path $t 'dirlink') -Value $outside | Out-Null
            New-Item -ItemType SymbolicLink -Path (Join-Path $t 'filelink.txt') -Value (Join-Path $outside 'keep.txt') | Out-Null
        } catch {
            throw "could not make a symbolic link here (needs Administrator or Developer Mode): $($_.Exception.Message)"
        }
        Remove-TreeNoFollow -LiteralPath $t
        Assert (Test-Gone $t) 'the folder is still there'
        Assert-OutsideWhole
    }

    Case 'a junction whose target is gone is removed' {
        $t = Join-Path $base 'tree4'
        $gone = Join-Path $base 'gone'
        New-Item -ItemType Directory -Path $t, $gone -Force | Out-Null
        New-Junction (Join-Path $t 'dangling') $gone
        [System.IO.Directory]::Delete($gone, $false)
        Remove-TreeNoFollow -LiteralPath $t
        Assert (Test-Gone $t) 'the folder is still there'
    }

    Case 'nothing to delete is not an error' {
        Remove-TreeNoFollow -LiteralPath (Join-Path $base 'missing\nothing')
        Remove-TreeNoFollow -LiteralPath (Join-Path $base 'missing') -Root $base
    }

    Case 'a share root is refused' {
        # A share that does not exist, so nothing could be deleted even if the refusal were missing.
        $threw = $null
        try { Remove-TreeNoFollow -LiteralPath '\\localhost\wp-no-such-share-7f3c\' } catch { $threw = $_.Exception.Message }
        Assert ($threw -match 'drive or share root') "no refusal: '$threw'"
    }

    Case 'with -Root, a link between the root and the folder stops the delete' {
        $game = Join-Path $base 'game1'
        New-Item -ItemType Directory -Path $game -Force | Out-Null
        $real = Join-Path $base 'elsewhere1'
        New-Item -ItemType Directory -Path (Join-Path $real 'map_tiles.old') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $real 'map_tiles.old\keep.txt'), 'keep')
        New-Junction (Join-Path $game 'windrose_plus_data') $real
        $threw = $null
        try { Remove-TreeNoFollow -LiteralPath (Join-Path $game 'windrose_plus_data\map_tiles.old') -Root $game } catch { $threw = $_.Exception.Message }
        Assert ($threw -match 'is a link, not a plain folder') "no refusal: '$threw'"
        Assert (Test-Path -LiteralPath (Join-Path $real 'map_tiles.old\keep.txt')) 'the folder behind the link was deleted'
        [System.IO.Directory]::Delete((Join-Path $game 'windrose_plus_data'), $false)
    }

    Case 'with -Root, plain folders on the way delete as usual, and a path outside the root needs no walk' {
        $game = Join-Path $base 'game2'
        $t = Join-Path $game 'windrose_plus_data\catalog\build_tmp'
        New-Item -ItemType Directory -Path (Join-Path $t 'x') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $t 'x\y.txt'), 'y')
        Remove-TreeNoFollow -LiteralPath $t -Root $game
        Assert (Test-Gone $t) 'the folder under the root is still there'
        Assert (Test-Path -LiteralPath (Join-Path $game 'windrose_plus_data\catalog')) 'more than the folder was deleted'
        $other = Join-Path $base 'other\tmp'
        New-Item -ItemType Directory -Path $other -Force | Out-Null
        Remove-TreeNoFollow -LiteralPath $other -Root $game
        Assert (Test-Gone $other) 'the folder outside the root is still there'
    }

    # The catalog builder itself: an old build_tmp holding a junction is cleared without touching the junction's
    # target. A stand-in repak that fails right away ends the run after that step.
    $stub = Join-Path $base 'repak-stub.cmd'
    [System.IO.File]::WriteAllText($stub, "@exit /b 3`r`n")
    Case 'the catalog builder clears an old build_tmp without following a junction in it' {
        $game = Join-Path $base 'game3'
        New-Item -ItemType Directory -Path (Join-Path $game 'R5\Content\Paks') -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $game 'R5\Content\Paks\pakchunk0-WindowsServer.pak'), [byte[]](1, 2, 3, 4))
        $buildTmp = Join-Path $game 'windrose_plus_data\catalog\build_tmp'
        New-Item -ItemType Directory -Path $buildTmp -Force | Out-Null
        New-Junction (Join-Path $buildTmp 'planted') $outside
        $r = Invoke-Catalog $game $stub
        Assert ($r.Code -eq 3 -and $r.Output -match 'repak unpack failed') "exit $($r.Code): $($r.Output)"
        Assert (Test-Gone (Join-Path $buildTmp 'planted')) 'the junction is still in build_tmp'
        Assert-OutsideWhole
    }
    Case 'the catalog builder refuses to clear build_tmp when its data folder is a link' {
        $game = Join-Path $base 'game4'
        New-Item -ItemType Directory -Path (Join-Path $game 'R5\Content\Paks') -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $game 'R5\Content\Paks\pakchunk0-WindowsServer.pak'), [byte[]](1, 2, 3, 4))
        $real = Join-Path $base 'elsewhere4'
        New-Item -ItemType Directory -Path (Join-Path $real 'catalog\build_tmp') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $real 'catalog\build_tmp\keep.txt'), 'keep')
        New-Junction (Join-Path $game 'windrose_plus_data') $real
        $r = Invoke-Catalog $game $stub
        Assert ($r.Code -ne 0 -and $r.Output -match 'is a link, not a plain folder') "exit $($r.Code): $($r.Output)"
        Assert (Test-Path -LiteralPath (Join-Path $real 'catalog\build_tmp\keep.txt')) 'the folder behind the link was deleted'
        [System.IO.Directory]::Delete((Join-Path $game 'windrose_plus_data'), $false)
    }
} finally {
    # rmdir /s removes junctions and links as links
    cmd /c "rmdir /s /q `"$base`"" | Out-Null
}

if ($failed) { Write-Host "$failed case(s) failed"; exit 1 }
Write-Host 'All no-follow delete cases passed.'
