#requires -Modules Az.Resources

# The logger is loaded here when the caller has not loaded it yet. The guard keeps the logger of the caller intact,
# because loading it again would reset the error state that the logger keeps.
if (-not (Get-Command -Name Write-AdoLogMessage -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Write-AdoLogMessage.ps1')
}

<#
    .SYNOPSIS
    Creates or updates a custom Azure Policy definition from a JSON file.

    .DESCRIPTION
    This function reads a custom Azure Policy definition from a local JSON file and applies it to
    a management group.

    The definition is created when it does not exist yet, and updated when the 'version' value in
    its metadata differs from the deployed one. When the versions match, nothing is changed.
    Files without a 'version' value in the metadata are skipped with a warning.

    The function logs through Write-AdoLogMessage. Dot sourcing this file loads Write-AdoLogMessage.ps1
    from the same folder, unless the caller has already loaded it.

    .PARAMETER PolicyFilePath
    The policy definition JSON file. Expects the name, properties.metadata.version,
    properties.policyRule and optionally properties.displayName, description, mode and parameters.

    .PARAMETER ManagementGroupName
    The name of the management group the policy definition is created or updated in.

    .EXAMPLE
    $policyFiles = Get-ChildItem -Path ".\policies" -Filter "*.json"

    foreach ($policyFile in $policyFiles) {
        $azPolicyDefinitionFromJsonArgs = @{
            PolicyFilePath      = $policyFile
            ManagementGroupName = "mg-platform"
        }
        Set-AzPolicyDefinitionFromJson @azPolicyDefinitionFromJsonArgs
    }

    .NOTES
    Version     : 1.0.0
    Author      : Jev - @devjevnl | https://www.devjev.nl
    Source      : https://github.com/thecloudexplorers/simply-scripted

    .LINK
    https://learn.microsoft.com/en-us/powershell/module/az.resources/new-azpolicydefinition?wt.mc_id=DT-MVP-5005327
#>
function Set-AzPolicyDefinitionFromJson {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.IO.FileInfo] $PolicyFilePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.String] $ManagementGroupName
    )

    $policyObject = Get-Content -Path $PolicyFilePath.FullName -Raw | ConvertFrom-Json
    $policyName = $policyObject.name
    $policyVersion = $policyObject.properties.metadata.version

    if ([string]::IsNullOrEmpty($policyVersion)) {
        $logArgs = @{
            Message = "  Policy file [$($PolicyFilePath.Name)] does not have a 'version' property. Skipping this policy."
            Type    = "Warning"
        }
        Write-AdoLogMessage @logArgs
        return
    }

    $policyDefinitionArguments = @{
        Name                = $policyName
        DisplayName         = $policyObject.properties.displayName
        Description         = $policyObject.properties.description
        Metadata            = $policyObject.properties.metadata | ConvertTo-Json -Depth 100
        Policy              = $policyObject.properties.policyRule | ConvertTo-Json -Depth 100
        ManagementGroupName = $ManagementGroupName
    }

    # Optional values are only passed when present, as ConvertTo-Json turns $null into the string "null"
    if ($null -ne $policyObject.properties.parameters) {
        $policyDefinitionArguments.Parameter = $policyObject.properties.parameters | ConvertTo-Json -Depth 100
    }
    if (-not [string]::IsNullOrEmpty($policyObject.properties.mode)) {
        $policyDefinitionArguments.Mode = $policyObject.properties.mode
    }

    $logArgs = @{
        Message = "  Checking if policy definition [$policyName] already exists in [$ManagementGroupName]"
        Type    = "Information"
    }
    Write-AdoLogMessage @logArgs

    # A missing definition throws a terminating error that -ErrorAction cannot suppress
    try {
        $existingPolicy = Get-AzPolicyDefinition -Name $policyName -ManagementGroupName $ManagementGroupName -ErrorAction Stop
    }
    catch {
        if ($_.Exception.Message -notmatch 'PolicyDefinitionNotFound|NotFound|could not be found') {
            throw
        }
        $existingPolicy = $null
    }

    if ($null -eq $existingPolicy) {
        $logArgs = @{
            Message = "  Creating a new Azure policy definition: [$policyName] - [$($PolicyFilePath.Name)]"
            Type    = "Information"
        }
        Write-AdoLogMessage @logArgs

        if ($PSCmdlet.ShouldProcess($policyName, "New-AzPolicyDefinition")) {
            New-AzPolicyDefinition @policyDefinitionArguments
        }
        return
    }

    # Az.Resources 7 and later return the metadata as a dictionary under AdditionalProperties
    $existingMetadata = $existingPolicy.Metadata
    $existingVersion = if ($null -ne $existingMetadata.AdditionalProperties) { $existingMetadata.AdditionalProperties['version'] } else { $existingMetadata.version }

    if ($existingVersion -eq $policyVersion) {
        $logArgs = @{
            Message = "  Policy version is the same for [$policyName] - [$($PolicyFilePath.Name)], no changes will be applied"
            Type    = "Information"
        }
        Write-AdoLogMessage @logArgs
        return
    }

    $logArgs = @{
        Message = "  Updating existing Azure policy definition: [$policyName] - [$($PolicyFilePath.Name)]"
        Type    = "Information"
    }
    Write-AdoLogMessage @logArgs

    if ($PSCmdlet.ShouldProcess($policyName, "Set-AzPolicyDefinition")) {
        Set-AzPolicyDefinition @policyDefinitionArguments
    }
}
