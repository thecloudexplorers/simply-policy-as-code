# The logger is loaded here when the caller has not loaded it yet. The guard keeps the logger of the caller intact,
# because loading it again would reset the error state that the logger keeps.
if (-not (Get-Command -Name Write-AdoLogMessage -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Write-AdoLogMessage.ps1')
}

<#
    .SYNOPSIS
    Logs the outcome of an Azure deployment.

    .DESCRIPTION
    Logs a single line with the provisioning state of the deployment. In debug mode the full deployment object is
    logged as well. Debug mode is on when -Debug is used, $DebugPreference is not SilentlyContinue, or the Azure
    DevOps variable System.Debug is true.

    Nothing is logged when the deployment is $null, because a failed deployment returns no object and its errors
    are logged by the caller.

    .PARAMETER Deployment
    The deployment object returned by the New-Az*Deployment cmdlets.

    .EXAMPLE
    Write-AdoDeploymentResult -Deployment $deployment
#>
function Write-AdoDeploymentResult {
    [CmdletBinding()]
    param (
        [Parameter()]
        [AllowNull()]
        [System.Object] $Deployment
    )

    if ($null -eq $Deployment) {
        return
    }

    $logArgs = @{
        Message = " Deployment [$($Deployment.ProvisioningState)]"
        Type    = "Information"
    }
    Write-AdoLogMessage @logArgs

    $debugEnabled = ($DebugPreference -ne 'SilentlyContinue') -or ($env:SYSTEM_DEBUG -eq 'true')
    if ($debugEnabled) {
        # Azure DevOps formats a single line per command, so every line is logged separately
        $deploymentLines = $Deployment | Format-List | Out-String -Stream | Where-Object { $_.Trim() }
        foreach ($deploymentLine in $deploymentLines) {
            $logArgs = @{
                Message    = $deploymentLine
                Type       = "Information"
                FormatType = "Debug"
            }
            Write-AdoLogMessage @logArgs
        }
    }
}
