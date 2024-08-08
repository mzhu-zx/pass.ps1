[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("init", "ls", "grep", "find", "show", "insert", "edit", "generate", "rm", "mv", "cp", "git", "help")]
    [string]$Command,

    # Relative path parameter is required for all commands
    [Parameter(Mandatory = $true, Position = 1)]
    [string]$RelativePath,


    # Clipboard
    [Alias("c")]
    [switch]$Clip,

    [Parameter(Position = 2)]
    [int] $PasswordLength,

    [ValidateSet("alphnum", "punct-alphnum")]
    [string] $PasswordStyle = "punct-alphnum"
)


Set-StrictMode -Version Latest

$PasswordStoreName = ".password-store"
$PasswordStorePath = "$HOME\$PasswordStoreName"

if (! (Test-Path -Path $PasswordStorePath)) {
    $PasswordStorePath = "$env:HOME\$PasswordStoreName"
    if (! (Test-Path -Path $PasswordStorePath)) {
        throw "No password store exists!"
    }
}

$AbsolutePath = Join-Path $PasswordStorePath $RelativePath
$KeyPath = $AbsolutePath + ".gpg"
$GpgId = Get-Content (Join-Path $PasswordStorePath ".gpg-id")
$GpgOpts = @("--quiet", "--yes", "--compress-algo=none", "--no-encrypt-to")
$ExcludeGit = @{
    Exclude = ".git*", ".gpg*"
}

Set-Variable -name LeafFormat -value ([string]"|-- ") -option Constant
Set-Variable -name LastLeafFormat -value ([string]"``-- ") -option Constant
Set-Variable -name TrunkFormat -value ([string]"|   ") -option Constant

<# 
    Prettyprint an IsoRecursive Rose Tree

#>
function Out-Tree {
    Param(
        $Path
    )    
    Out-TreeInternal (Get-Item $Path) -Depth 0
}

function Out-TreeInternal {
    Param(
        $Info,
        [int]$Depth,
        [bool]$Last
    )

    if ($Depth -eq 0) {
        $Format = "{0}"
    } 
    else {
        $Format = $TrunkFormat * ($Depth - 1) + ($Last ? $LastLeafFormat : $LeafFormat) + "{0}";
    }

    $KeyName = ($Info.Name -match "(?<path>.*).gpg") ? $Matches['path'] : $Info.Name
    if (-not ($KeyName -like ".*" )) {
        Write-Host ($Format -f $KeyName)
    }
    
    If (Test-Path -Path $Info.FullName -PathType Container) {
        $Children = (Get-ChildItem @ExcludeGit $Info.FullName)
        if ($Children -is [object[]]) {
            switch ($Children.Length) {
                0 { return; }
                1 { Out-TreeInternal $Children[0] ($Depth + 1) $true }
                Default {
                    foreach ($child in $Children[0..($Children.Length - 2)]) {
                        Out-TreeInternal $child ($Depth + 1)
                    }
                    Out-TreeInternal $Children[$Children.Length - 1] ($Depth + 1) $true
                }
            }
        }
        else {
            Out-TreeInternal $Children ($Depth + 1) $true
        }
    }
}

function Write-Password {
    param ( [string] $Password )
    if ($Clip) {
        Write-Debug "Write to clipboard!"
        Set-Clipboard $Password
    }
    else {
        return $Password
    }
}

# pass show
function Get-PasswordItems {
    if (Test-Path $AbsolutePath -PathType Container) {
        return (Out-Tree $AbsolutePath)
    }
    else {
        return Read-Password
    }
}

function Read-Password {
    $Path = $KeyPath
    $Password = (gpg.exe --decrypt $Path)
    return (Write-Password $Password)
}

# pass find
function Get-PasswordFile {
    # $ParentPath = Split-Path $RelativePath
    $LeafPath = Split-Path -Leaf $RelativePath
    # $LeafLike = "*$LeafPath*"
    $LikeOptions = @{
        # Include = $LeafLike
        Recurse = $true
    }
    $Like = Get-ChildItem -Path $PasswordStorePath @ExcludeGit |
    Get-ChildItem @LikeOptions |
    Where-Object { $_.FullName | Select-String -Pattern $LeafPath } |
    Resolve-Path -RelativeBasePath $PasswordStorePath -Relative |
    ForEach-Object {
        if ($_ -match ".\\(?<path>.*).gpg") {
            $matches['path']            
        }
        else {
            $_
        }
    }
    return $Like
}

$Charset = ""

# pass generate
function New-Password {
    $Path = $KeyPath
    if (Test-Path $Path) {
        $Confirmation = Read-Host "An entry already exists for $RelativePath. Overwrite it? [y/N] "
        if ($Confirmation -ne "y") {
            exit
        }
    }
    switch ($PasswordStyle) {
        punct-alphnum {
            $Charset = [char[]](33..126)
        }
        alphnum {
            $Charset = ([char[]]('a'..'z') + [char[]]('A'..'Z') + [char[]](48..57))
        }
    }
    $Charset = $Charset -join ''
    Write-Debug "$Charset"
    $RandomParams = @{
        Count   = $PasswordLength
        Minimum = 0
        Maximum = $Charset.Length
    }
    $NewPassword = (Get-SecureRandom @RandomParams
        | ForEach-Object { $Charset[$_] }) -join ''


    $KeyDir = Split-Path $KeyPath -Parent
    if (! (Test-Path $KeyDir)) {
        [void](New-Item -Type Directory -Path $KeyDir )
    }

    Write-Output $NewPassword | gpg.exe -e -r $GpgId -o $KeyPath @GpgOpts

    return (Write-Password $NewPassword)
}

# pass insert

# pass ls


switch ($Command) {
    generate { New-Password }
    insert { }
    find { Get-PasswordFile }
    show { Get-PasswordItems }
    ls {
        Out-Tree $PasswordStorePath
    }
    default {
        Write-Host "$CommandOrPath has not been implemented yet."
    }
}