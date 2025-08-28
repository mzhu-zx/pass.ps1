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
        [Parameter(Position = 0)]
        [ArgumentCompleter({ Invoke-PassPathCompleter @args })]
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
        [ArgumentCompleter({ Invoke-PassPathCompleter @args })]
        [string]$Pattern
    )
    $PassStorePath = Get-PasswordStore
    $LikeOptions = @{
        Recurse = $true
    }

    $Like = (Get-ChildItem -Path $PassStorePath @ExcludeGit |
        Get-ChildItem @LikeOptions |
        Where-Object { $_.FullName | Select-String -Pattern $Pattern } |
        ForEach-Object { Resolve-PassName $_ $PassStorePath })
    return $Like
}

$AlphNumCharset = ([char[]]([char]'a'..[char]'z') + `
        [char[]]([char]'A'..[char]'Z') + `
        [char[]](48..57)) -join ''
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
        [ArgumentCompleter({ Invoke-PassPathCompleter @args })]
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
        [ArgumentCompleter({ Invoke-PassPathCompleter @args })]
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
        [ArgumentCompleter({ Invoke-PassPathCompleter @args })]
        [string] $OldPassName,
        [Parameter(Mandatory)]
        [ArgumentCompleter({ Invoke-PassPathCompleter @args })]
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
    Copy-Item $OldItem.FullName $NewItemPath -Force:$Force
    Invoke-GitAddCopied -OldPath $OldPassName -NewPath $NewPassName -NewItemPath $NewItemPath
}

function Invoke-PassRename {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ArgumentCompleter({ Invoke-PassPathCompleter @args })]
        [string] $OldPassName,
        [Parameter(Mandatory)]
        [ArgumentCompleter({ Invoke-PassPathCompleter @args })]
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

# ## TOTP (RFC 6238) Support  
<#
.SYNOPSIS
Insert an TOTP URL into an existing password file. If the PassName is not
specified, use Otp's label instead.
#>
function Invoke-PassOtpInsert {
    [CmdletBinding()]
    param (
        [switch] $Echo,
        [switch] $Force,
        [string] $PassName,
        [Parameter(Mandatory)]
        [string] $TotpUrl
    )

    $PassOtpSplat = @{
        Echo     = $Echo
        Force    = $Force   
        PassName = $PassName 
        TotpUrl  = $TotpUrl
    }
    Invoke-PassOtpInsertOrAppend @PassOtpSplat
}

<#
.SYNOPSIS
Append an TOTP URL into an existing password file. If the PassName is not 
specified, use Otp's label instead.
#>
function Invoke-PassOtpAppend {
    [CmdletBinding()]
    param (
        [switch] $Echo,
        [switch] $Force,
        [string] $PassName,
        [Parameter(Mandatory)]
        [string] $TotpUrl
    )

    $PassOtpSplat = @{
        Append   = $True
        Echo     = $Echo
        Force    = $Force   
        PassName = $PassName 
        TotpUrl  = $TotpUrl
    }
    Invoke-PassOtpInsertOrAppend @PassOtpSplat
}

<#
.SYNOPSIS
Compute the current OTP.
#>
function Invoke-PassOtp {
    [CmdletBinding()]
    param (
        [string] $PassName
    )
    $Plaintext = Invoke-PassShow $PassName
    $Totp = Resolve-TotpUrl $Plaintext
    if (-not $Totp) {
        throw "No TOTP URL found in $PassName"
    }
    $Now = ([System.DateTimeOffset]::Now.ToUnixTimeSeconds())
    Resolve-Totp -Secret $Totp.Secret -Interval $Totp.Period -Digits $Totp.Digits -Time $Now
}

#BEGIN Git Helper
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


function Invoke-GitRename(
    $OldPassName, $NewPassName, $OldPassPath, $NewPassPath, $Force
) {
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
        [ArgumentCompleter({ Invoke-PassPathCompleter @args })]
        [string]$PassName = ''
    )    
    $PassPath = Get-RealPath $PassName -IsContainer $true
    Write-Debug "Path: $PassPath"
    Out-Tree $PassPath
}
#END Git Helper

#BEGIN OTP Helper
function Invoke-PassOtpInsertOrAppend {
    [CmdletBiding()]
    param (
        [switch] $Echo,
        [switch] $Force,
        [string] $PassName,
        [Parameter(Mandatory)]
        [string] $TotpUrl,
        [switch] $Append
    )
    $ParsedTotp = Resolve-TotpUrl $TotpUrl
    if (-not $ParsedTotp) {
        Write-Error "${TotpUrl} doesn't seem to be a valid TOTP URL."
        return
    }
    $PassNameOrLabel = if (-not $PassName) { $Account } else { $PassName }

    if ($Append) {
        try {
            $Plaintext = Invoke-PassShow $PassNameOrLabel
        }
        catch { }
    }
    $Plaintext += " ${TotpUri}"

    $PassInsertSplat = @{
        Echo      = $Echo
        Force     = $Force   
        PassName  = $PassNameOrLabel 
        Plaintext = $Plaintext
    }
    Invoke-PassInsert @PassInsertSplat
}

<#
.SYNOPSIS
Compute the current TOTP value. 

.PARAMETER  SECRET
Base32 Encoded 

.DESCRIPTION

T/HTOP uses Big-Endian extensively:
- The step, previous the Counter value, is 8-byte long, (UINT64_BE)
- The secret is directly from the BASE32 conversion (MSB-first)
- The final result is 4-byte long, (UINT32_BE)
#>
function Resolve-Totp([string]$Secret, [uint64]$Interval, [int]$Digits, [uint64]$Time) {
    $DIGITS_POWER = @( 1,10,100,1000,10000,100000,1000000,10000000,100000000 )
    $Step = [uint64][System.Math]::DivRem($Time, $Interval, [ref]$null)
    $MsgBuffer = [System.BitConverter]::GetBytes($Step)
    $KBuffer = ConvertFrom-Base32BE $Secret
    if ([System.BitConverter]::IsLittleEndian) {
        [array]::Reverse($MsgBuffer)
    }
    $hmac = [System.Security.Cryptography.HMACSHA1]::new($KBuffer)
    $hash = $Hmac.ComputeHash($MsgBuffer)
    $offset = $hash[$hash.length - 1] -band 0xf
    $hash = $hash[$offset..($offset+3)]
    if ([System.BitConverter]::IsLittleEndian) {
        [array]::Reverse($hash)
    }
    $binary = [System.BitConverter]::ToUInt32($hash, 0) -band 0x7fffffff
    $otp = $binary % $DIGITS_POWER[$Digits]
    $otp.ToString().PadLeft($Digits, '0')
}

<#
.SYNOPSIS
Convert Base32-encoded string into bytes.
#>
function ConvertFrom-Base32BE([string]$encoded) {
    $bytes = [byte[]]::new([math]::DivRem((7 + 5 * $encoded.Length),  8, [ref]$null))
    $nbits = 0; $ibyte = 0
    foreach ($c in $encoded.ToUpperInvariant().ToCharArray()) {
        $v = if (('A' -le $c) -and ($c -le 'Z')) { [int]([char]$c - [char]'A') } else { 26 + [int]([char]$c - [char]'2') }
        $nbits += 5 
        if ($nbits -lt 8) {
            $bytes[$ibyte] = $bytes[$ibyte] -bor ($v -shl (8 - $nbits))
        }
        else {
            # bits to be placed in the next byte
            $nbits %= 8
            $bytes[$ibyte] = $bytes[$ibyte] -bor ($v -shr $nbits)
            $ibyte ++
            $bmask = (1 -shl $nbits) - 1
            if ($bmask -ne 0) {
                $bytes[$ibyte] = $bytes[$ibyte] -bor (($v -band $bmask) -shl (8 - $nbits))
            }
        }
    }
    $bytes
}
#END OTP Helper

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
function Resolve-PassName {
    param(
        [System.IO.FileSystemInfo]$PassItem,
        [string]$PassStorePath
    )
    # Use the Polyfill for 5.1
    $RelativePath = Resolve-RelativePath $PassItem.FullName $PassStorePath
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
Compute the relative path of the path w.r.t. the second path. If the first is 
not an offspring of the reference path, the result is undefined.
#>
function Resolve-RelativePath {
    param(
        [string]$AbsolutePath, 
        [string]$ReferencePath
    )
    if ($AbsolutePath.StartsWith($ReferencePath)) {
        $AbsolutePath.Substring($ReferencePath.Length)
    }
    else {
        throw "'$AbsolutePath' doesn't start with '$ReferencePath'"
    }
}

<#
.SYNOPSIS
Display an item in the form of a tree.
#>
function Out-Tree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        $Path
    )
    Out-TreeInternal (Get-Item $Path) -Depth 0
}

function Out-TreeInternal {
    param(
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
        $CurrentTrunkFormat = if ($Last) { '    ' } else { '|   ' }
        $Format = $Format + $CurrentTrunkFormat

    }

    $KeyName = if ($Info.Name -match '(?<path>.*).gpg') { $Matches['path'] } else { $Info.Name }
    if (-not ($KeyName -like '.*' )) {
        Write-Debug $KeyName
        Write-Output ($DisplayFormat -f $KeyName)
    }

    if (Test-Path -Path $Info.FullName -PathType Container) {
        $Children = @(Get-ChildItem @ExcludeGit $Info.FullName)
        switch ($Children.Length) {
            0 { break; }
            1 {
                Out-TreeInternal -Info $Children[0] -Depth ($Depth + 1) -Format $Format  -Last
                break
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
Get the normalized (absolute and ended with a trailing '/') path to the password store.

The path is PASSWORD_STREO_DIR; otherwise, "$HOME/.password-store/".
#>
function Get-PasswordStore {
    $PassStorePath = $env:PASSWORD_STORE_DIR
    if (-not $PassStorePath) {
        $PassStorePath = "$HOME/.password-store"
    }
    $PassStorePath = Resolve-Path "$PassStorePath/"
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


## OTP Utilities

function Format-TotpUrl([string]$Account, [string]$Secret, [string]$Issuer) {
    $EncodedIssuer = [uri]::EscapeDataString($Issuer)
    if (-not $Issuer) {
        "otpauth://totp/${Account}?secret=${Secret}"
    }
    else {
        "otpauth://totp/${$EncodedIssuer}:${Account}?secret=${Secret}&issuer={$EncodedIssuer}"
    }
}

function Resolve-TotpUrl([string]$TotpUrl) {
    if ($TotpUrl -match "otpauth://\S+") {
        $TotpUrl = $Matches.0
    } else {
        return $null
    }
    $uri = [uri]$TotpUrl
    if ($uri -and ($uri.Authority -eq "totp")) {
        $DecodedLabel = [uri]::UnescapeDataString($uri.LocalPath.Substring(1)) -split ':'
        if ($DecodedLabel.Length -eq 1) {
            $Account = $DecodedLabel[0]
            $Issuer = ''
        }
        elseif ($DecodedLabel.Length -eq 2) {
            $Account = $DecodedLabel[1]
            $Issuer = $DecodedLabel[0]
        }

        $Digits = 6
        if ($uri.Query -match "[?&]digits=(?<Digits>\d+)") {
            $Digits = [int]$Matches.Digits
        }

        $Period = 30
        if ($uri.Query -match "[?&]period=(?<Period>\d+)") {
            $Period = [int]$Matches.Period
        }

        if ($uri.Query -match "[?&]secret=(?<Secret>[^&]+)") {
            $Secret = $Matches.Secret
        } else {
            return $null
        }

        return @{
            Account = $Account
            Issuer  = $Issuer
            Secret  = $Secret
            Digits  = $Digits
            Period  = $Period
        }
    }
}

## Completions Utilities

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
    ([Runtime.InteropServices.Marshal]::PtrToStringAuto(`
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR(`
            $(Read-Host -AsSecureString -Prompt $Prompt))))
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
            otp {
                Invoke-PassOtp @ArgsRest
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

function Invoke-PassArgumentCompleter {
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


function Invoke-PassPathCompleter {
    param (
        $commandName,
        $parameterName,
        $wordToComplete,
        $commandAst,
        $fakeBoundParameters
    )
    Get-PassPathCompletion $wordToComplete
}
function Get-PassPathCompletion ($wordToComplete) {
    $PassStorePath = Get-PasswordStore
    $PassPath = "$(Join-Path $PassStorePath $wordToComplete)*"
    $suggestions = (Get-ChildItem $PassPath |
        ForEach-Object { Resolve-PassName $_ $PassStorePath })
    $suggestions
}

Set-Alias -Name 'pass' -Value 'Invoke-Pass'

$ExportSubcommandSplat = @{
    Function = @(
        'Invoke-Pass'
        'Invoke-PassArgumentCompleter'
        'Invoke-PassPathCompleter'
        'Invoke-PassInit'
        'Invoke-PassShow'
        'Invoke-PassGenerate'
        'Invoke-PassInsert'
        'Invoke-PassList'
        'Invoke-PassFind'
        'Invoke-PassGit'
        'Invoke-PassOtp'
        'Invoke-PassOtpInsert'
        'Invoke-PassOtpAppend'
        'Resolve-TotpUrl'
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
    $nativeCompleter = {
        param (
            $wordToComplete,
            $commandAst,
            $cursorPosition
        )
        Get-PassPathCompletion $wordToComplete
    }
    Register-ArgumentCompleter -CommandName Invoke-Pass -ScriptBlock $nativeCompleter
    Register-ArgumentCompleter -CommandName pass -ScriptBlock $nativeCompleter
}

Install-PassCompanion
