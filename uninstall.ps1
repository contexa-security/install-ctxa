#Requires -Version 5.1

& {
    $hadInstallAction = Test-Path Env:CONTEXA_INSTALL_ACTION
    $previousInstallAction = $env:CONTEXA_INSTALL_ACTION

    try {
        $env:CONTEXA_INSTALL_ACTION = 'uninstall'
        $installer = Invoke-WebRequest 'https://install.ctxa.ai/install.ps1' -UseBasicParsing
        & ([scriptblock]::Create($installer.Content))
    } finally {
        if ($hadInstallAction) {
            $env:CONTEXA_INSTALL_ACTION = $previousInstallAction
        } else {
            Remove-Item Env:CONTEXA_INSTALL_ACTION -ErrorAction SilentlyContinue
        }
    }
}
