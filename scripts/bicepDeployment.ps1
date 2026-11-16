#Requires -PSEdition Core
#Requires -Modules Az.Resources
<#
    .SYNOPSIS
    Deploys a Bicep template at the requested scope.

    .DESCRIPTION
    Routes deployment to the correct scope based on DeploymentScope.
    Tenant scope uses the dedicated helper function.

    .PARAMETER TemplateFile
    Path to the Bicep template file.

    .PARAMETER TemplateParameterFile
    Path to the Bicep parameters file.

    .PARAMETER DeploymentScope
    Target scope for the deployment.

    .PARAMETER ManagementGroupId
    The ID of the management group for management group scope deployments.

    .PARAMETER Location
    The location for the deployment.

    .PARAMETER DeploymentDescription
    Optional. A short description that replaces the scope prefix of the deployment name, for example
    "TenantPolicyAssignments" instead of "ManagementGroupScopeDeployment". The deployment name is
    "<DeploymentDescription>-<yyyyMMdd-HHmmss>". Azure limits a deployment name to 64 characters and the timestamp
    takes 16, so the description is limited to 48 characters. Only letters, numbers, periods, underscores, hyphens
    and parentheses are allowed. Deployments to the same scope with the same description in the same second
    get the same name, so give each deployment a different description.

    .PARAMETER StopOnDeploymentError
    Controls what happens when the deployment fails.

    By default the script continues: the deployment errors are logged as Azure DevOps warnings, so the
    step is reported as succeeded with issues and later pipeline steps still run.

    With this switch the deployment errors are logged as Azure DevOps errors, the step is marked as
    failed and the script ends with exit code 1. Later pipeline steps that use the default
    succeeded() condition are skipped.

    .EXAMPLE
    $params = @{
        TemplateFile = "C:\templates\main.bicep"
        TemplateParameterFile = "C:\templates\main.bicepparam"
        DeploymentScope = "tenant"
        ManagementGroupId = "ContosoRootManagementGroup"
        Location = "West Europe"
    }
    .\bicepDeployment.ps1 @params

    .NOTES
    Version     : 1.0.0
    Author      : Jev - @devjevnl | https://www.devjev.nl
    Source      : https://github.com/thecloudexplorers/simply-scripted
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [System.String] $TemplateFile,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [System.String] $TemplateParameterFile,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('tenant', 'managementGroup', 'subscription', 'resourceGroup')]
    [System.String] $DeploymentScope,

    [Parameter()]
    [System.String] $DeploymentScopeManagementGroupId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [System.String] $Location,

    [Parameter()]
    [System.String] $SubscriptionId,

    [Parameter()]
    [ValidateLength(1, 48)]
    [ValidatePattern('^[A-Za-z0-9._()-]+$')]
    [System.String] $DeploymentDescription,

    [Parameter()]
    [System.Management.Automation.SwitchParameter] $StopOnDeploymentError
)

# Errors do not stop the script by default. The deployment cmdlets collect their own errors instead,
# see $commonDeploymentParams. A throw, such as a missing SubscriptionId, is always terminating.
$ErrorActionPreference = 'Continue'

# Load Write-AdoLogMessage function via dot sourcing
# Write-Host with the debug command is used here because Write-AdoLogMessage is not yet available
Write-Host "##[debug]Importing Write-AdoLogMessage.ps1"
$writeAdoLogMessage = Join-Path $PSScriptRoot "functions\Write-AdoLogMessage.ps1"
. $writeAdoLogMessage

Write-AdoLogMessage -Message "Importing Write-AdoDeploymentResult.ps1" -Type "Information" -FormatType "Debug"
$writeAdoDeploymentResult = Join-Path $PSScriptRoot "functions\Write-AdoDeploymentResult.ps1"
. $writeAdoDeploymentResult
# Applied to the deployment cmdlets only. Errors and warnings are collected instead of printed, so they can be
# logged as Azure DevOps errors and warnings. A failed deployment does not end the script by itself.
$commonDeploymentParams = @{
    ErrorAction     = 'SilentlyContinue'
    ErrorVariable   = 'deploymentErrors'
    WarningAction   = 'SilentlyContinue'
    WarningVariable = 'deploymentWarnings'
}
$deploymentErrors = @()
$deploymentWarnings = @()
$deploymentFailure = $null

try {
    switch ($DeploymentScope) {
        "tenant" {
            # Tenant Scope Deployment

            $deploymentNamePrefix = if ($DeploymentDescription) { $DeploymentDescription } else { "TenantScopeDeployment" }
            $fullDeploymentName = "$deploymentNamePrefix-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

            $tenantDeploymentParams = @{
                TemplateFile          = $TemplateFile
                TemplateParameterFile = $TemplateParameterFile
                Location              = $Location
                DeploymentName        = $fullDeploymentName
            }

            Write-AdoLogMessage -Message "Starting tenant-scope deployment" -Type "Information"
            # Splats the tenant specific parameters, plus the common parameters that collect errors and warnings
            $deployment = New-AzTenantDeployment @tenantDeploymentParams @commonDeploymentParams
            Write-AdoDeploymentResult -Deployment $deployment
            if ($deploymentErrors.Count -eq 0) {
                Write-AdoLogMessage -Message "Completed Tenant Scope Deployment" -Type "Information"
            }
        }
        "managementGroup" {

            # Management Group Scope Deployment
            $deploymentNamePrefix = if ($DeploymentDescription) { $DeploymentDescription } else { "ManagementGroupScopeDeployment" }
            $fullDeploymentName = "$deploymentNamePrefix-$(Get-Date -Format 'yyyyMMdd-HHmmss')"


            $managementGroupDeploymentParams = @{
                ManagementGroupId     = $DeploymentScopeManagementGroupId
                TemplateFile          = $TemplateFile
                TemplateParameterFile = $TemplateParameterFile
                Location              = $Location
                DeploymentName        = $fullDeploymentName
            }

            Write-AdoLogMessage -Message "Starting management group-scope deployment" -Type "Information"
            Write-AdoLogMessage -Message " Deploying to management group: [$($DeploymentScopeManagementGroupId)]" -Type "Information"
            Write-AdoLogMessage -Message " Deployment Name: [$($fullDeploymentName)]" -Type "Information"
            # Splats the management group specific parameters, plus the common parameters that collect errors and warnings
            $deployment = New-AzManagementGroupDeployment @managementGroupDeploymentParams @commonDeploymentParams
            Write-AdoDeploymentResult -Deployment $deployment
            if ($deploymentErrors.Count -eq 0) {
                Write-AdoLogMessage -Message "Completed Management Group Scope Deployment" -Type "Information"
                Write-Host ""
            }

        }
        "subscription" {
            # Subscription Scope Deployment
            $deploymentNamePrefix = if ($DeploymentDescription) { $DeploymentDescription } else { "SubscriptionScopeDeployment" }
            $deploymentName = "$deploymentNamePrefix-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

            # Check if SubscriptionId is provided
            if ([string]::IsNullOrEmpty($SubscriptionId)) {
                throw [System.ArgumentException]::new("SubscriptionId is required for subscription scope deployment.")
            }

            $subscription = Get-AzSubscription -SubscriptionId $SubscriptionId

            if ($null -eq $subscription) {
                throw [System.ArgumentException]::new("Subscription with ID '$SubscriptionId' not found.")
            }

            Write-AdoLogMessage -Message "Deploying to subscription: [$($subscription.Name)] - Id: [$($subscription.Id)]" -Type "Information"
            # Redirects only the success stream to $null, so the context table is hidden but warnings and errors are not
            Set-AzContext -Subscription $SubscriptionId 1> $null

            $subscriptionDeploymentParams = @{
                TemplateFile          = $TemplateFile
                TemplateParameterFile = $TemplateParameterFile
                Location              = $Location
                DeploymentName        = $deploymentName
            }

            Write-AdoLogMessage -Message "Starting subscription-scope deployment" -Type "Information"
            # Splats the subscription specific parameters, plus the common parameters that collect errors and warnings
            $deployment = New-AzSubscriptionDeployment @subscriptionDeploymentParams @commonDeploymentParams
            Write-AdoDeploymentResult -Deployment $deployment
            if ($deploymentErrors.Count -eq 0) {
                Write-AdoLogMessage -Message "Completed Subscription Scope Deployment" -Type "Information"
            }
        }
        "default" {
            # Resource Group Scope Deployment
            default {
                # Resource Group Scope Deployment
                throw [System.NotImplementedException]::new("Resource Group Scope Deployment, not yet implemented")
            }
        }
    }
} catch {
    $deploymentFailure = $_
}

# Logged once for every scope, also after a failure, and before the errors so the warnings are not lost
foreach ($deploymentWarning in $deploymentWarnings) {
    $logArgs = @{
        Message = $deploymentWarning.Message
        Type    = "Warning"
    }
    Write-AdoLogMessage @logArgs
}

# An Azure DevOps error marks the step as failed, which skips the later steps with the default succeeded() condition.
# By default the deployment errors are therefore logged as warnings, so the pipeline continues.
$deploymentErrorType = if ($StopOnDeploymentError) { "Error" } else { "Warning" }
foreach ($deploymentError in $deploymentErrors) {
    # Azure DevOps only colours the first line of a multi-line issue, so the lines are joined into a single line
    $errorLines = @($deploymentError.Exception.Message -split '\r?\n' | ForEach-Object { $_.Trim().TrimStart('-').Trim() } | Where-Object { $_ })
    $logArgs = @{
        Message = "Deployment failed: $($errorLines -join ' | ')"
        Type    = $deploymentErrorType
    }
    Write-AdoLogMessage @logArgs
}

# A terminating error, such as a missing SubscriptionId, always ends the script
if ($null -ne $deploymentFailure) {
    $logArgs = @{
        Message = "Deployment failed: [$($deploymentFailure.Exception.Message)]"
        Type    = "Error"
        # Exit logs the error and ends the script with exit code 1, Stop would throw and print the error twice
        Action  = "Exit"
    }
    Write-AdoLogMessage @logArgs
}

# The errors are already logged as errors, only end the script with exit code 1 when asked to stop
if ($StopOnDeploymentError -and $deploymentErrors.Count -gt 0) {
    exit 1
}
