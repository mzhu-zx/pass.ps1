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



begin {
    Set-StrictMode -Version Latest
    $LeafFormat = "|-- "
    $LastLeafFormat = "``-- "
    $TrunkFormat = "|   "
}

<# 
Constant Definitions
#>
process {

    $PasswordStoreName = ".password-store"
    $PasswordStorePath = "$HOME\$PasswordStoreName"

    if (! (Test-Path -Path $PasswordStorePath)) {
        $PasswordStorePath = "$env:HOME\$PasswordStoreName"
        if (! (Test-Path -Path $PasswordStorePath)) {
            throw "No password store exists!"
        }
    }

    $GpgId = Get-Content (Join-Path $PasswordStorePath ".gpg-id")
    $GpgOpts = @("--quiet", "--yes", "--compress-algo=none", "--no-encrypt-to")
    $ExcludeGit = @{
        Exclude = ".git*", ".gpg*"
    }        

    $AbsolutePath = Join-Path $PasswordStorePath $RelativePath
    $KeyPath = $AbsolutePath + ".gpg"

    function Out-Tree {
        Param(
            $Path
        )    
        Out-TreeInternal (Get-Item $Path) -Depth 0
    }

    function Out-TreeInternal {
        Param(
            [System.IO.FileSystemInfo] $Info,
            [int] $Depth,
            [switch] $Last
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
    function Get-PasswordItem {
        if (Test-Path $AbsolutePath -PathType Container) {
            return (Out-Tree $AbsolutePath)
        }
        else {
            Get-Password        
        }
    }

    function Get-Password {
        $Path = $KeyPath
        if (Test-Path $KeyPath -PathType Leaf) {
            $Password = (gpg.exe --decrypt $Path)
            return (Write-Password $Password)
        }
        else {
            Write-Host "Error: ${RelativePath} is not in the password store."
            exit -1
        }
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
    function Set-Password {
        param (
            [switch] $Generate,
            $NewPassword
        )
    
        $Path = $KeyPath
        if (Test-Path $Path) {
            $Confirmation = Read-Host "An entry already exists for $RelativePath. Overwrite it? [y/N] "
            if ($Confirmation -ne "y") {
                exit
            }
        }

        if ($Generate) {
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
        }
        else {
            if (-not $NewPassword) {
                $NewPassword = Read-Host "Enter password for ${RelativePath}`:" -AsSecureString
                $RetypePassword = Read-Host "Retype password for ${RelativePath}`:" -AsSecureString
                if ($NewPassword -ne $RetypePassword) {
                    Write-Host "Error: the entered passwords do not match."
                    exit -1
                }
            }
        }
        Write-Output $NewPassword | gpg.exe -e -r $GpgId -o $KeyPath @GpgOpts

        return (Write-Password $NewPassword)
    }


    # pass rm
    function Remove-PasswordFile {
        param (
            [switch] $Generate,
            $NewPassword
        )
    
        $Path = $KeyPath
        if (Test-Path $Path) {
            $Confirmation = Read-Host "Are you sure you would like to delete ${RelativePath}? [y/N]"
            if ($Confirmation -ne "y") {
                exit
            }
            Remove-Item $Path
        }
        else {
            Write-Host "Error: ${RelativePath} is not in the password store."
            exit
        }
    }


    switch ($Command) {
        rm { Remove-PasswordFile }
        generate { Set-Password -Generate }
        insert { Set-Password }
        find { Get-PasswordFile }
        show { Get-PasswordItem }
        ls {
            Out-Tree $PasswordStorePath
        }
        default {
            Write-Host "$CommandOrPath has not been implemented yet."
        }
    }
}
