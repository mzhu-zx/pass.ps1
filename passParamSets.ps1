[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, Position = 0, ParameterSetName="Insert")]
    [switch]$Insert,
    [Parameter(Mandatory=$true, Position = 0, ParameterSetName="Show")]
    [switch]$Show,
    [Parameter(Mandatory=$true, Position = 0, ParameterSetName="Generate")]
    [switch]$Generate,
    [Parameter(Mandatory=$true, Position = 0, ParameterSetName="Find")]
    [switch]$Find,

    # Relative path parameter is required for all commands
    [Parameter(Mandatory=$true, Position = 1)]
    [switch]$RelativePath,


    # Clipboard
    [Parameter(ParameterSetName="Generate")]
    [Parameter(ParameterSetName="Show")]
    [switch]$Clip
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

# pass show
function Read-Password {
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$RelativePath,

        [switch]$Clip
    )
    $Path = (Join-Path -Path $PasswordStorePath -ChildPath $RelativePath) + ".gpg"
    $Password = (gpg.exe --decrypt $Path)
    if ($Clip) {
        Write-Debug "Write to clipboard!"
        Set-Clipboard $Password
    }
    else {
        return $Password
    }
}

# pass find
function Get-PasswordFile {
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        $RelativePath
    )
    $ParentPath = Split-Path $RelativePath
    $LeafPath = Split-Path -Leaf $RelativePath
    $LeafLike = "*$LeafPath*"
    $CoarsePass = @{
        Path    = (Join-Path $PasswordStorePath -ChildPath $ParentPath)
        Exclude = ".git*"
    }
    $LikeOptions = @{
        Include = $LeafLike
        Recurse = $true
    }
    $Like =
    Get-ChildItem @CoarsePass | 
    Get-ChildItem @LikeOptions | 
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

# pass generate

# pass insert

# pass ls


generate { }
insert { }
find { Get-PasswordFile @args }
show { Read-Password    @args }
default {
    Write-Host "$CommandOrPath has not been implemented yet."
}
