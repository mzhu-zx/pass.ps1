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

$KeyPath = (Join-Path $PasswordStorePath $RelativePath) + ".gpg"
$GpgId = Get-Content (Join-Path $PasswordStorePath ".gpg-id")
$GpgOpts = @("--quiet", "--yes", "--compress-algo=none", "--no-encrypt-to")

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
    $CoarsePass = @{
        # Path    = (Join-Path $PasswordStorePath -ChildPath $ParentPath)
        Path    =  $PasswordStorePath
        Exclude = ".git*"
    }
    $LikeOptions = @{
        # Include = $LeafLike
        Recurse = $true
    }
    # $Like = Get-ChildItem @CoarsePass |
    #     Get-ChildItem @LikeOptions |
    #     Resolve-Path -RelativeBasePath $PasswordStorePath -Relative |
    #     ForEach-Object {
    #         if ($_ -match ".\\(?<path>.*).gpg") {
    #             $matches['path']            
    #         }
    #         else {
    #             $_
    #         }
    #     }
    $Like = Get-ChildItem @CoarsePass |
        Get-ChildItem @LikeOptions |
        Where-Object {  $_.FullName | Select-String -Pattern $LeafPath } |
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
    show { Read-Password }
    ls {
        tree /f $PasswordStorePath
    }
    default {
        Write-Host "$CommandOrPath has not been implemented yet."
    }
}
