$ErrorActionPreference = "Stop"

function Resolve-Error ($ErrorRecord = $Error[0]) {
    $ErrorRecord | Format-List * -Force
    $ErrorRecord.InvocationInfo |Format-List *
    $Exception = $ErrorRecord.Exception
    for ($i = 0; $Exception; $i++, ($Exception = $Exception.InnerException)) {
        “$i” * 80
        $Exception |Format-List * -Force
    }
}

Import-Module $PSScriptRoot/../Pass.psm1 -PassThru
$env:PASSWORD_STORE_DIR = "$PSScriptRoot/password-store-test/"

if (Test-Path $env:PASSWORD_STORE_DIR) {
    Remove-Item -Recurse $env:PASSWORD_STORE_DIR -Force
}
try { 
    Invoke-PassInit -GpgId "test@example.com"
    Invoke-PassGit init
    Invoke-PassGit add -A 
    Invoke-PassGit commit -m "init"

    Invoke-PassInsert "example.com/test@example.com" "1234"
    Test-Path "$env:PASSWORD_STORE_DIR/example.com/test@example.com.gpg"
    Invoke-PassShow "example.com/test@example.com"
    Invoke-PassInsert "example.com/test@example.com" "1234"

    Invoke-PassGenerate "example2.com/test@example.com" 16
    Test-Path "$env:PASSWORD_STORE_DIR/example2.com/test@example.com.gpg"
    Invoke-PassGenerate "example2.com/test@example.com" 16
    Invoke-PassShow "example2.com/test@example.com"
    Invoke-PassFind "example"
}
catch {
    Resolve-Error $Error 
}
