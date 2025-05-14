#Requires -Version 5.1
using namespace System.Management.Automation
using namespace System.Collections.ObjectModel

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest


# Constant Definitions
$LeafFormat = '|-- '
$LastLeafFormat = "``-- "
$TrunkFormat = '|   '
$GpgOpts = @('--quiet', '--yes', '--compress-algo=none', '--no-encrypt-to')
$ExcludeGit = @{
    Exclude = '.git*', '.gpg*'
}

if (-not (Test-Path Env:\PASSWORD_STORE_GENERATED_LENGTH)) {
    $env:PASSWORD_STORE_GENERATED_LENGTH = 16
}


# pass show
function Invoke-PassShow {
    [CmdletBinding()]
    param (
        [ArgumentCompleter({ PassPathCompleter @args })]
        [Parameter(Position = 0)]
        [string]$PassName = '',
        [switch]$Clip
    )
    $PassItem = Get-PassItem $PassName
    if ($PassItem.PSIsContainer) {
        Out-Tree $PassItem.FullName
    }
    else {
        $Plaintext = (gpg.exe --decrypt $PassItem.FullName)
        $PassHostSplat = @{
            Text = $Plaintext
            Clip = $Clip
        }
        Write-PassHost @PassHostSplat
    }
}

# pass find
function Invoke-PassFind {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$Pattern
    )
    $PassStorePath = Get-PasswordStore
    $LikeOptions = @{
        Recurse = $true
    }

    $Like = (Get-ChildItem -Path $PassStorePath @ExcludeGit |
        Get-ChildItem @LikeOptions |
        Where-Object { $_.FullName | Select-String -Pattern $Pattern } |
        ForEach-Object { Get-PassName $_ $PassStorePath })
    return $Like
}

$AlphNumCharset = ([char[]]([char]'a'..[char]'z') + [char[]]([char]'A'..[char]'Z') + [char[]](48..57)) -join ''
$PunctAlphNumCharset = ([char[]](33..126)) -join ''

function Invoke-PassGenerate {
    [CmdletBinding()]
    param (
        [switch] $NoSymbols,
        [switch] $Clip,
        # [switch] $InPlace, # not implemnted
        [switch] $Force,
        [Parameter(Mandatory, Position = 0)]
        [string] $PassName,
        [Parameter(Position = 1)]
        [int] $PassLength,
        [ValidateSet('Alphnum', 'PunctAlphnum')]
        [string] $PassStyle
    )
    $PassPath = Get-RealPath $PassName -MakeParentDirectoy $true
    if ((Test-Path $PassPath) -and (-not $Force)) {
        $Confirmation = Read-Host "An entry already exists for $PassName. Overwrite it? [y/N] "
        if ($Confirmation -ne 'y') {
            throw 'User interrupted.'
        }
    }

    if (-not $PassStyle) {
        $PassStyle = if ($NoSymbols) { 'Alphnum' } else { 'PunctAlphnum' }
    }

    switch ($PassStyle) {
        PunctAlphNum {
            $Charset = $PunctAlphNumCharset
        }
        Alphnum {
            $Charset = $AlphNumCharset
        }
    }
    $RandomParams = @{
        Minimum = 0
        Maximum = $Charset.Length
    }

    if (-not $PassLength) {
        $PassLength = $env:PASSWORD_STORE_GENERATED_LENGTH
    }

    $GeneratedPass = (
        1..$PassLength | ForEach-Object { $Charset[(Get-Random @RandomParams)] }
    ) -join ''

    Write-PassFile -Plaintext $GeneratedPass -PassPath $PassPath
    $PassHostSplat = @{
        Text = $GeneratedPass
        Clip = $Clip
    }
    Write-PassHost @PassHostSplat
    Invoke-GitAdd -PassName $PassName -PassPath $PassPath -IsGenerated $true
}

function Invoke-PassInsert {
    [CmdletBinding()]
    param (
        [switch] $Echo,
        [switch] $Force,
        [Parameter(Mandatory, Position = 0)]
        [string] $PassName,
        [Parameter(Position = 1)]        
        [string] $Plaintext
    )
    $PassPath = Get-RealPath $PassName -MakeParentDirectoy $true
    if ((Test-Path $PassPath) -and (-not $Force)) {
        $Confirmation = Read-Host "An entry already exists for $PassName. Overwrite it? [y/N] "
        if ($Confirmation -ne 'y') {
            throw 'User interrupted.'
        }
    }

    if (-not $Plaintext) {
        $NewPass = Read-HostMasked "Enter password for ${PassName}" 
        $RetypePass = Read-HostMasked "Retype password for ${PassName}"
        if ($NewPass -ne $RetypePass) {
            throw 'the entered passwords do not match.'
        }
        $Plaintext = $NewPass
    }
    Write-PassFile -Plaintext $Plaintext -PassPath $PassPath
    if ($Echo) {
        Write-PassHost -Text $Plaintext
    }
    Invoke-GitAdd -PassName $PassName -PassPath $PassPath -IsGenerated $false
}


# pass rm
function Invoke-PassRemove {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$PassName
    )
    $PassItem = Get-PassItem $PassName
    $PassPath = $PassItem.FullName
    $Confirmation = Read-Host "Are you sure you would like to delete ${PassName}? [y/N]"
    if ($Confirmation -eq 'y') {
        Invoke-GitRemove $PassName $PassPath
    }
    else {
        throw 'User interrupted.'
    }
}


# pass init
function Invoke-PassInit {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string[]] $gpgId,
        [string] $Path
    )
    # Limitation: it only updates the gpg-id file without re-encrypting
    $PassStorePath = Get-PasswordStore
    $InitPath = Join-Path $PassStorePath $Path
    if (Test-Path -PathType Leaf $InitPath) {
        throw "$PassStorePath exists but is not a directory."
    }

    if (-not (Test-Path $InitPath)) {
        # Create directory if not exists yet.
        New-Item $InitPath -ItemType Directory
    }

    $Path = if ($Path) { $Path } else { $PassStorePath }
    $GpgIdPath = "$Path/.gpg-id"
    if ($gpgId.Count -eq 0) {
        throw 'Init command must contain at least one gpg-id'
    }

    if (($gpgId.Count -eq 1) -and ($gpgId[0] -eq '')) {
        Remove-Item $GpgIdPath
    }
    if ($gpgId.Count -gt 0) {
        if (Test-Path $GpgIdPath -PathType Leaf) {
            $answer = Read-Host "Pass for Pwsh doesn't support re-encryption. Are you sure to continue? (y/n)"
            if (-not ($answer -ieq 'y')) {
                Write-Warning "$GpgIdPath was not modified."
                return
            }
        }
        Set-Content $GpgIdPath -Value ($gpgId -join '`n')
    }
}

function Invoke-PassCopy {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $OldPassName,
        [Parameter(Mandatory)]
        [string] $NewPassName,
        [switch] $Force
    )

    [System.IO.FileSystemInfo]$OldItem = Get-PassItem $OldPassName
    $IsContainer = $OldItem.PSIsContainer
    $NewItemPath = Get-RealPath -RelativePath $NewPassName -IsContainer $IsContainer
    if ((Test-Path $NewItemPath) -and (-not $Force)) {
        $Confirmation = Read-Host "An entry already exists for $NewPassName. Overwrite it? [y/N] "
        if ($Confirmation -ne 'y') {
            throw 'User interrupted.'
        }
    }
    $forceSplat = @{ Force = $Force }
    Copy-Item $OldItem.FullName $NewItemPath @forceSplat
    Invoke-GitAddCopied -OldPath $OldPassName -NewPath $NewPassName -NewItemPath $NewItemPath
}

function Invoke-PassRename {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $OldPassName,
        [Parameter(Mandatory)]
        [string] $NewPassName,
        [switch] $Force
    )

    [System.IO.FileSystemInfo]$OldItem = Get-PassItem $OldPassName
    $IsContainer = $OldItem.PSIsContainer
    $NewItemPath = Get-RealPath -RelativePath $NewPath -IsContainer $IsContainer
    $RenameSplat = @{
        OldPassPath = $OldItem.FullName
        NewPassPath = $NewItemPath
        OldPassName = $OldPassName
        NewPassName = $NewPassName
        Force       = $Force
    }
    Invoke-GitRename @RenameSplat
}

###########################################################################
# Git Helper
###########################################################################

function Invoke-GitCommit($Message) {
    $GitWorkDir = Get-PasswordStore
    git -C $GitWorkDir commit -m $Message
}

function Invoke-GitAdd($PassName, $PassPath, $IsGenerated) {
    $GitWorkDir = Get-PasswordStore
    git -C $GitWorkDir add $PassPath
    $Message = if ($IsGenerated) {
        "Add generated password for $PassName"
    }
    else {
        "Add given password for $PassName to store"
    }
    Invoke-GitCommit $Message
}

function Invoke-GitAddCopied($OldPath, $NewPath, $NewItemPath) {
    $GitWorkDir = Get-PasswordStore
    git -C $GitWorkDir add $NewItemPath
    $Message = "Copy $OldPath to $NewPath."
    Invoke-GitCommit $Message
}


function Invoke-GitRename($OldPassName, $NewPassName, $OldPassPath, $NewPassPath, $Force) {
    $GitWorkDir = Get-PasswordStore
    $forceSplat = if ($Force) { @('--force') } else { @() }
    git -C $GitWorkDir mv $OldPassPath $NewPassPath @forceSplat
    Invoke-GitCommit "Rename $OldPassName to $NewPassName"
}

function Invoke-GitRemove($PassName, $PassPath) {
    $GitWorkDir = Get-PasswordStore
    git -C $GitWorkDir rm $PassPath
    Invoke-GitCommit "Remove $PassName from store."
}

function Invoke-PassGit {
    $GitWorkDir = Get-PasswordStore
    git -C $GitWorkDir @args
}


function Invoke-PassList {
    [CmdletBinding()]
    param (
        [string]$PassName = ''
    )    
    $PassPath = Get-RealPath $PassName -IsContainer $true
    Write-Debug "Path: $PassPath"
    Out-Tree $PassPath
}

###########################################################################
# Utilities
###########################################################################
<#
.SYNOPSIS
Resolve the real item from a relative path. If the path ends with a
trailing '/' or '\', it is treated as a directory.

The item must exists.
#>
function Get-PassItem {
    param (
        [string]$RelativePath
    )
    $PassStorePath = Get-PasswordStore
    $FullPath = Join-Path $PassStorePath $RelativePath
    if (Test-Path -PathType Container $FullPath) {
        return (Get-Item $FullPath)
    }

    $FullPath += '.gpg'
    if (Test-Path -PathType Leaf $FullPath) {
        return (Get-Item $FullPath)
    }

    throw "$RelativePath is not in the password store."
}

<#
.SYNOPSIS
Resolve the absolute path from a relative path to the root of the pass store.
#>
function Get-RealPath {
    param (
        [string]$RelativePath,
        [bool]$IsContainer,
        [bool]$MakeParentDirectoy
    )
    $PassStorePath = Get-PasswordStore
    $FullPath = Join-Path $PassStorePath $RelativePath
    if (-not $IsContainer) {
        $FullPath += '.gpg'
    }
    if ($MakeParentDirectoy) {
        $Parent = Split-Path $FullPath -Parent
        if (-not (Test-Path $Parent)) {
            $null = New-Item -Type Directory -Path $Parent
        }
    }
    return $FullPath
}

<#
Convert a file item into a password store name.
#>
function Get-PassName {
    param(
        [System.IO.FileSystemInfo]$PassItem,
        [string]$PassStorePath
    )
    $RelativePath = Resolve-Path -Path $PassItem.FullName -RelativeBasePath $PassStorePath -Relative
    $strip = if ($RelativePath -match '(.\\)?(?<path>.*)') {
        $matches['path']
    }
    else {
        $_
    }
    if ($PassItem.PSIsContainer) {
        $strip = Join-Path $strip '\'
    }
    else {
        if ($strip -match '(?<path>.*).gpg') {
            $strip = $matches['path']
        }
    }
    return $strip
}


<#
.SYNOPSIS
Display an item in the form of a tree.
#>
function Out-Tree {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory, Position = 0)]
        $Path
    )
    Out-TreeInternal (Get-Item $Path) -Depth 0
}

function Out-TreeInternal {
    Param(
        [System.IO.FileSystemInfo] $Info,
        [int] $Depth,
        [string] $Format,
        [switch] $Last
    )
    if (-not $Info) {
        return
    }

    Write-Debug $Info
    
    if ($Depth -eq 0) {
        $DisplayFormat = '{0}'
    }
    else {
        $CurrentLeafFormat = if ($Last) { $LastLeafFormat } else { $LeafFormat }
        $DisplayFormat = $Format + $CurrentLeafFormat + '{0}'
        $CurrentTrunkFormat = if ($Last) { "    " } else { "|   " }
        $Format = $Format + $CurrentTrunkFormat

    }

    $KeyName = if ($Info.Name -match '(?<path>.*).gpg') { $Matches['path'] } else { $Info.Name }
    if (-not ($KeyName -like '.*' )) {
        Write-Debug $KeyName
        Write-Output ($DisplayFormat -f $KeyName)
    }

    If (Test-Path -Path $Info.FullName -PathType Container) {
        $Children = @(Get-ChildItem @ExcludeGit $Info.FullName)
        switch ($Children.Length) {
            0 { break; }
            1 {
                Out-TreeInternal -Info $Children[0] -Depth ($Depth + 1) -Format $Format  -Last;
                break;
            }
            Default {
                foreach ($child in $Children[0..($Children.Length - 2)]) {
                    Out-TreeInternal -Info $child -Depth ($Depth + 1)  -Format $Format
                }
                Out-TreeInternal -Info $Children[$Children.Length - 1] -Depth ($Depth + 1)  -Format $Format -Last
            }
        }
    }
}

<#
.SYNOPSIS
Get the path to the password store.

The path is PASSWORD_STREO_DIR; otherwise, "$HOME/.password-store".
#>
function Get-PasswordStore {
    $PassStorePath = $env:PASSWORD_STORE_DIR
    if (-not $PassStorePath) {
        $PassStorePath = "$HOME/.password-store"
    }
    return $PassStorePath
}

<#
.SYNOPSIS
Get the root GPG ID.

TODO: Support get gpg id of the nearest root.
#>
function Get-GpgId {
    $PassStorePath = Get-PasswordStore
    Get-Content (Join-Path $PassStorePath '.gpg-id')
}

<#
.SYNOPSIS
Encrypt and write the plaintext to the given path.
#>
function Write-PassFile {
    param (
        [string]$Plaintext,
        [string]$PassPath
    )
    $GpgId = Get-GpgId
    $commands = "gpg.exe -e -r $GpgId -o $PassPath $GpgOpts" 
    Write-Debug $commands
    Write-Output $Plaintext | gpg.exe -e -r $GpgId -o $PassPath @GpgOpts
}


<#
.SYNOPSIS
Write the text to the host or copy it to the clipboard.
#>
function Write-PassHost {
    param ([string] $Text, [switch] $Clip)
    if ($Clip) {
        Write-Debug 'Write to clipboard!'
        Set-Clipboard $Text
    }
    else {
        return $Text
    }
}


<#
.SYNOPSIS
Utility function to simplify adding attributes in dynamic parameters.
#>
function Add-Parameter {
    param (
        [string] $ParameterName,
        [System.Type] $ParameterType,
        [RuntimeDefinedParameterDictionary] $Dict,
        [ParameterAttribute] $Attribute = @{},
        [string[]] $ValidateSet,
        [string] $Alias
    )
    $attributes = [Collection[System.Attribute]]::new()
    $attributes.Add($Attribute)
    if ($ValidateSet) {
        $validateSetAttribute = [ValidateSetAttribute]::new($ValidateSet)
        $attributes.Add($validateSetAttribute)
    }
    if ($Alias) {
        $aliasAttribute = [AliasAttribute]::new($Alias)
        $attributes.Add($aliasAttribute)
    }
    $parameter = [RuntimeDefinedParameter]::new(
        $ParameterName, $ParameterType, $attributes
    )
    $Dict.Add($ParameterName, $parameter)
    return
}

function Read-HostMasked {
    param (
        [string] $Prompt
    )
    ([Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($(Read-Host -AsSecureString -Prompt $Prompt))))
}

###########################################################################
# CLI Wrapper
###########################################################################

# Function Definitions
function Invoke-Pass {
    process {
        $ArgList = $args
        $Length = $ArgList.Count
        if ($ArgList) {
            $Subcommand = $ArgList[0]
            $ArgsRest = @(if ($Length -gt 1) { $ArgList[1..($Length - 1)] } else { @() })
        }
        else {
            $Subcommand = 'show'
            $ArgsRest = @()
        }
        switch ($Subcommand) {
            init {
                Invoke-PassInit @ArgsRest
            }
            generate {
                Invoke-PassGenerate @ArgsRest
                break
            }
            { $_ -in @('add', 'insert') } {
                Invoke-PassInsert @ArgsRest
                break
            }
            { $_ -in @('rm', 'remove', 'delete') } {
                Invoke-PassRemove @ArgsRest
                break
            }
            { $_ -in @('cp', 'copy') } {
                Invoke-PassCopy @ArgsRest
                break
            }
            find {
                Invoke-PassFind @ArgsRest
                break
            }
            show {
                Invoke-PassShow @ArgsRest
                break
            }
            { $_ -in @('ls', 'list') } {
                Invoke-PassList @ArgsRest
                break
            }
            git {
                Invoke-PassGit @ArgsRest
                break
            }
            { $_ -in @('grep', 'edit', 'help', 'version') } {
                throw "PASS-PS: $Subcommand has not been implemented yet."
            }
            Default {
                Invoke-PassShow @args
            }
        }
    }
}

# Register-ArgumentCompleter -CommandName Invoke-Pass -ScriptBlock { PassArgumentCompleter @args }

function PassArgumentCompleter {
    param (
        $commandName,
        $parameterName,
        $wordToComplete,
        $commandAst,
        $fakeBoundParameters
    )

    $subcommands = @(
        'init'
        'ls', 'list'
        'grep'
        'find', 'search'
        'show'
        'insert', 'add'
        'edit'
        'generate'
        'rm', 'delete', 'remove'
        'mv', 'rename'
        'cp', 'copy'
        'git'
        'help'
        'version'
    )

    $subcommands | Where-Object { $_ -like "$wordToComplete*" }
}


function PassPathCompleter {
    param (
        $commandName,
        $parameterName,
        $wordToComplete,
        $commandAst,
        $fakeBoundParameters
    )
    $PassStorePath = Get-PasswordStore
    $PassPath = "$(Join-Path $PassStorePath $wordToComplete)*"
    $suggestions = (Get-ChildItem $PassPath) | ForEach-Object { Get-PassName $_ $PassStorePath }
    $suggestions
}

Set-Alias -Name 'pass' -Value 'Invoke-Pass'

$ExportSubcommandSplat = @{
    Function = @(
        'Invoke-Pass'
        'PassArgumentCompleter'
        'PassPathCompleter'
        'Invoke-PassInit'
        'Invoke-PassShow'
        'Invoke-PassGenerate'
        'Invoke-PassInsert'
        'Invoke-PassList'
        'Invoke-PassFind'
        'Invoke-PassGit'
    )
    Alias    = @(
        'pass'
    )
}
Export-ModuleMember @ExportSubcommandSplat
<#
.SYNOPSIS
Install completers for the Pass module.

.DESCRIPTION
Install completers for the Pass module.

.EXAMPLE


.NOTES

#>
function Install-PassCompanion {
    Register-ArgumentCompleter -CommandName Invoke-Pass -ScriptBlock ${function:PassArgumentCompleter}
}

Export-ModuleMember -Function Install-PassCompanion
