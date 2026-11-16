#requires -Modules Az.Resources

# The logger is loaded here when the caller has not loaded it yet. The guard keeps the logger of the caller intact,
# because loading it again would reset the error state that the logger keeps.
if (-not (Get-Command -Name Write-AdoLogMessage -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Write-AdoLogMessage.ps1')
}

<#
    .SYNOPSIS
    Creates or updates an Azure Policy initiative (policy set definition) from a JSON file.

    .DESCRIPTION
    This function reads a custom Azure Policy initiative from a local JSON file and applies it to
    a management group.

    The initiative is created when it does not exist yet, and updated when the 'version' value in
    its metadata differs from the deployed one. When the versions match, nothing is changed.
    Files without a 'version' value in the metadata are skipped with a warning.

    The function logs through Write-AdoLogMessage. Dot sourcing this file loads Write-AdoLogMessage.ps1
    from the same folder, unless the caller has already loaded it.

    .PARAMETER PolicySetFilePath
    The initiative JSON file. Expects the name, properties.metadata.version and properties.policyDefinitions
    and optionally properties.displayName, description, parameters and policyDefinitionGroups.

    .PARAMETER ManagementGroupName
    The name of the management group the initiative is created or updated in.

    .EXAMPLE
    $policySetFiles = Get-ChildItem -Path ".\initiatives" -Filter "*.initiative.json"

    foreach ($policySetFile in $policySetFiles) {
        $azPolicyInitiativeDefinitionFromJsonArgs = @{
            PolicySetFilePath   = $policySetFile
            ManagementGroupName = "mg-platform"
        }
        Set-AzPolicyInitiativeDefinitionFromJson @azPolicyInitiativeDefinitionFromJsonArgs
    }

    .NOTES
    Version     : 1.0.0
    Author      : Jev - @devjevnl | https://www.devjev.nl
    Source      : https://github.com/thecloudexplorers/simply-scripted

    .LINK
    https://learn.microsoft.com/en-us/powershell/module/az.resources/new-azpolicysetdefinition?wt.mc_id=DT-MVP-5005327
#>
function Set-AzPolicyInitiativeDefinitionFromJson {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.IO.FileInfo] $PolicySetFilePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.String] $ManagementGroupName
    )

    $policySetObject = Get-Content -Path $PolicySetFilePath.FullName -Raw | ConvertFrom-Json
    $policySetName = $policySetObject.name
    $policySetVersion = $policySetObject.properties.metadata.version

    if ([string]::IsNullOrEmpty($policySetVersion)) {
        $logArgs = @{
            Message = "  Initiative file [$($PolicySetFilePath.Name)] does not have a 'version' property. Skipping this initiative."
            Type    = "Warning"
        }
        Write-AdoLogMessage @logArgs
        return
    }

    # InputObject keeps a single policy definition reference an array, which the cmdlet requires
    $policySetDefinitionArguments = @{
        Name                = $policySetName
        DisplayName         = $policySetObject.properties.displayName
        Description         = $policySetObject.properties.description
        Metadata            = $policySetObject.properties.metadata | ConvertTo-Json -Depth 100
        PolicyDefinition    = ConvertTo-Json -InputObject $policySetObject.properties.policyDefinitions -Depth 100 #TODO FIX THIS LINE
        ManagementGroupName = $ManagementGroupName
    }

    # Optional values are only passed when present, as ConvertTo-Json turns $null into the string "null"
    if ($null -ne $policySetObject.properties.parameters) {
        $policySetDefinitionArguments.Parameter = $policySetObject.properties.parameters | ConvertTo-Json -Depth 100
    }
    if ($null -ne $policySetObject.properties.policyDefinitionGroups) {
        $policySetDefinitionArguments.GroupDefinition = ConvertTo-Json -InputObject $policySetObject.properties.policyDefinitionGroups -Depth 100
    }

    $logArgs = @{
        Message = "  Checking if initiative [$policySetName] already exists in [$ManagementGroupName]"
        Type    = "Information"
    }
    Write-AdoLogMessage @logArgs

    # A missing initiative throws a terminating error that -ErrorAction cannot suppress
    try {
        $existingPolicySet = Get-AzPolicySetDefinition -Name $policySetName -ManagementGroupName $ManagementGroupName -ErrorAction Stop
    }
    catch {
        # The function Get-AzPolicySetDefinition does not honor -ErrorAction so we have to handle this ourselves
        if ($_.Exception.Message -notmatch '[PolicySetDefinitionNotFound]|NotFound|could not be found') {
            throw
        }
        $existingPolicySet = $null
    }

    if ($null -eq $existingPolicySet) {
        $logArgs = @{
            Message = "  Creating a new Azure initiative: [$policySetName] - [$($PolicySetFilePath.Name)]"
            Type    = "Information"
        }
        Write-AdoLogMessage @logArgs

        if ($PSCmdlet.ShouldProcess($policySetName, "New-AzPolicySetDefinition")) {
            New-AzPolicySetDefinition @policySetDefinitionArguments
        }
        return
    }

    # Az.Resources 7 and later return the metadata as a dictionary under AdditionalProperties
    $existingMetadata = $existingPolicySet.Metadata
    $existingVersion = if ($null -ne $existingMetadata.AdditionalProperties) { $existingMetadata.AdditionalProperties['version'] } else { $existingMetadata.version }

    if ($existingVersion -eq $policySetVersion) {
        $logArgs = @{
            Message = "  Initiative version is the same for [$policySetName] - [$($PolicySetFilePath.Name)], no changes will be applied"
            Type    = "Information"
        }
        Write-AdoLogMessage @logArgs
        return
    }

    $logArgs = @{
        Message = "  Updating existing Azure initiative: [$policySetName] - [$($PolicySetFilePath.Name)]"
        Type    = "Information"
    }
    Write-AdoLogMessage @logArgs

    if ($PSCmdlet.ShouldProcess($policySetName, "Set-AzPolicySetDefinition")) {
        Set-AzPolicySetDefinition @policySetDefinitionArguments
    }
}
