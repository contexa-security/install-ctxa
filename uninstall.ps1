#Requires -Version 5.1

& {
    $installer = Invoke-WebRequest 'https://install.ctxa.ai/install.ps1' -UseBasicParsing
    & ([scriptblock]::Create($installer.Content)) -Action uninstall
}
