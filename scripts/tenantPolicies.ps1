#Requires -PSEdition Core
#Requires -Modules Az.Resources
<#
    .SYNOPSIS
    Deploys custom Azure Policy definitions and initiatives from JSON files to a management group, and optionally the
    policy assignments that use them.

    .DESCRIPTION
    Looks for custom policy definition files (*.policy.json) and initiative files (*.initiative.json) in the
    configuration folder and deploys them to the management group.

    Policy definitions are deployed first, so an initiative can reference a custom policy definition that is deployed
    in the same run. Each file is created or updated by its own function, which only changes a definition or initiative
    when the 'version' value in its metadata differs from the deployed one.

    Finding no files is not an error, as the initiatives can consist of built-in policies only.

    When PolicyAssignmentFilesRootFolder is provided, the policy assignments are deployed after the definitions and
    initiatives. Every *.parameters.jsonc file in that folder is deployed with tenantPolicies.bicep through
    bicepDeployment.ps1, which also grants the assignment identities their roles.

    .PARAMETER RootRepoLocation
    The root folder of this repository, the folder that contains the scripts and bicep folders.

    .PARAMETER PolicyFilesRootFolder
    The folder that contains the *.policy.json and *.initiative.json files. The folder is searched without recursion,
    as the pipeline flattens the configuration folders.

    .PARAMETER DefinitionsDeploymentManagementGroupName
    The name of the management group the definitions and initiatives are deployed to. All definitions and initiatives
    of the run go to this one management group, a file cannot choose a different scope. The assignment deployments run
    at this management group as well, but it is never the target of an assignment, the target of every assignment is
    the TargetScope property in the assignment file.

    .PARAMETER PolicyAssignmentFilesRootFolder
    Optional. The folder that contains the *.parameters.jsonc files of the policy assignments. When provided, every file
    is deployed with tenantPolicies.bicep after the definitions and initiatives. The folder is searched without
    recursion. When omitted, no assignments are deployed.

    .PARAMETER DeploymentLocation
    The Azure region that stores the assignment deployment metadata. Required when PolicyAssignmentFilesRootFolder is
    provided.

    .PARAMETER UnmanagedAssignmentsAction
    Optional. Drift control for the assignments, one of Ignore (default), Report or Remove. After all assignment files
    are deployed, the assignments that exist on the management groups named in the TargetScope properties of the
    files, but are not in the files, are handled. Report only logs what would be removed, Remove deletes them.
    Only the assignments created directly on those management groups are considered, inherited ones are not.
    There is no marker on the assignments, so every assignment on those management groups that is not in the files
    is affected, regardless of who created it. Report and Remove require PolicyAssignmentFilesRootFolder and at least
    one assignment. Removing an assignment does not remove the role assignments of its identity.

    .PARAMETER UnmanagedAssignmentsExclusions
    Optional. Exclusion list for the drift control. Assignments with a name in this list are never reported or removed,
    even though they are not in the files, for example assignments that are created by another team. Wildcards are
    supported, for example "mcsb-*". The names apply to every management group that is checked. Only used when
    UnmanagedAssignmentsAction is Report or Remove.

    .PARAMETER UnmanagedDefinitionsAction
    Optional. Drift control for the custom definitions and initiatives, one of Ignore (default), Report or Remove. It
    runs last, after the assignments are deployed and their drift control is done. The custom initiatives and policy
    definitions on DefinitionsDeploymentManagementGroupName whose name is not in the files, are handled. Initiatives are
    removed before policy definitions. Report only logs what would be removed, Remove deletes them. There is no marker
    on the definitions, so every custom definition and initiative on that management group that is not in the files is
    affected, regardless of who created it. Use UnmanagedDefinitionsExclusions to protect definitions. Definitions that
    Azure refuses to remove, for example because an assignment still uses them, are logged as a warning and skipped.
    Report and Remove require at least one definition or initiative file. Removing cannot be undone.

    .PARAMETER UnmanagedDefinitionsExclusions
    Optional. Exclusion list for the definitions drift control. Definitions and initiatives with a name in this list are
    never reported or removed, even though they are not in the files, for example definitions that are created by
    another team. Wildcards are supported, for example "team-x-*". Only used when UnmanagedDefinitionsAction is
    Report or Remove.

    .EXAMPLE
    $params = @{
        RootRepoLocation                         = "C:\repos\simply-policy-as-code"
        PolicyFilesRootFolder                    = "C:\repos\simply-policy-as-code\configuration\policy-definitions"
        DefinitionsDeploymentManagementGroupName = "mg-contoso"
    }
    .\tenantPolicies.ps1 @params

    .EXAMPLE
    $params = @{
        RootRepoLocation                         = "C:\repos\simply-policy-as-code"
        PolicyFilesRootFolder                    = "C:\repos\simply-policy-as-code\configuration\policy-definitions"
        DefinitionsDeploymentManagementGroupName = "mg-contoso"
        PolicyAssignmentFilesRootFolder          = "C:\repos\simply-policy-as-code\configuration\policy-assignments"
        DeploymentLocation                       = "westeurope"
    }
    .\tenantPolicies.ps1 @params

    .EXAMPLE
    # Same as above, and previews the removal of assignments that are not in the files
    $params = @{
        RootRepoLocation                         = "C:\repos\simply-policy-as-code"
        PolicyFilesRootFolder                    = "C:\repos\simply-policy-as-code\configuration\policy-definitions"
        DefinitionsDeploymentManagementGroupName = "mg-contoso"
        PolicyAssignmentFilesRootFolder          = "C:\repos\simply-policy-as-code\configuration\policy-assignments"
        DeploymentLocation                       = "westeurope"
        UnmanagedAssignmentsAction               = "Report"
        UnmanagedAssignmentsExclusions           = @("mcsb-*", "team-x-audit")
    }
    .\tenantPolicies.ps1 @params

    .EXAMPLE
    # Same as above, and previews the removal of definitions and initiatives that are not in the files
    $params = @{
        RootRepoLocation                         = "C:\repos\simply-policy-as-code"
        PolicyFilesRootFolder                    = "C:\repos\simply-policy-as-code\configuration\policy-definitions"
        DefinitionsDeploymentManagementGroupName = "mg-contoso"
        PolicyAssignmentFilesRootFolder          = "C:\repos\simply-policy-as-code\configuration\policy-assignments"
        DeploymentLocation                       = "westeurope"
        UnmanagedAssignmentsAction               = "Report"
        UnmanagedDefinitionsAction               = "Report"
        UnmanagedDefinitionsExclusions           = @("team-x-*")
    }
    .\tenantPolicies.ps1 @params

    .NOTES
    Version     : 1.0.0
    Author      : Jev - @devjevnl | https://www.devjev.nl
    Source      : https://github.com/thecloudexplorers/simply-scripted

    Progress and errors are reported with Write-AdoLogMessage. The script ends with exit code 1 on the first terminating
    error.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [System.String] $RootRepoLocation,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [System.String] $PolicyFilesRootFolder,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [System.String] $DefinitionsDeploymentManagementGroupName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [System.String] $PolicyAssignmentFilesRootFolder,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [System.String] $DeploymentLocation,

    [Parameter()]
    [ValidateSet("Ignore", "Report", "Remove")]
    [System.String] $UnmanagedAssignmentsAction = "Ignore",

    [Parameter()]
    [System.String[]] $UnmanagedAssignmentsExclusions = @(),

    [Parameter()]
    [ValidateSet("Ignore", "Report", "Remove")]
    [System.String] $UnmanagedDefinitionsAction = "Ignore",

    [Parameter()]
    [System.String[]] $UnmanagedDefinitionsExclusions = @()
)

# Set errors to break script execution
$ErrorActionPreference = 'Stop'

# Load Write-AdoLogMessage function via dot sourcing
# Write-Host is used here because Write-AdoLogMessage is not yet available
Write-Host "Importing Write-AdoLogMessage.ps1"
$writeAdoLogMessage = "{0}\{1}" -f $RootRepoLocation, "scripts\functions\Write-AdoLogMessage.ps1"
. $writeAdoLogMessage

# Report every terminating error once, at the top of the script. Exit ends the script without rethrowing,
# so the pipeline task does not print the error a second time.
trap {
    $logArgs = @{
        Message = $_.Exception.Message
        Type    = "Error"
        # Exit logs the error and ends the script with exit code 1, Stop would throw and print the error twice
        Action  = "Exit"
    }
    Write-AdoLogMessage @logArgs
}

# Define the path to the functions folder containing common PowerShell scripts
$functionsFolder = Join-Path $RootRepoLocation "scripts\functions"

# Importing common functions from the functions folder
Write-AdoLogMessage -Message "Importing Set-AzPolicyDefinitionFromJson.ps1" -Type "Information"
. (Join-Path $functionsFolder "Set-AzPolicyDefinitionFromJson.ps1")

# Importing Set-AzPolicyInitiativeDefinitionFromJson.ps1 from the functions folder
Write-AdoLogMessage -Message "Importing Set-AzPolicyInitiativeDefinitionFromJson.ps1" -Type "Information"
. (Join-Path $functionsFolder "Set-AzPolicyInitiativeDefinitionFromJson.ps1")

# Importing Remove-AzPolicyAssignmentNotInConfig.ps1 from the functions folder
Write-AdoLogMessage -Message "Importing Remove-AzPolicyAssignmentNotInConfig.ps1" -Type "Information"
. (Join-Path $functionsFolder "Remove-AzPolicyAssignmentNotInConfig.ps1")

# Importing Remove-AzPolicyDefinitionNotInConfig.ps1 from the functions folder
Write-AdoLogMessage -Message "Importing Remove-AzPolicyDefinitionNotInConfig.ps1" -Type "Information"
. (Join-Path $functionsFolder "Remove-AzPolicyDefinitionNotInConfig.ps1")

# bicepDeployment.ps1 is a script with mandatory parameters, so it is only located here and dot sourced per assignment file
Write-AdoLogMessage -Message "Locating bicepDeployment.ps1" -Type "Information"
$bicepDeployment = "{0}\{1}" -f $RootRepoLocation, "scripts\bicepDeployment.ps1"
$tenantPoliciesTemplate = "{0}\{1}" -f $RootRepoLocation, "bicep\tenantPolicies.bicep"

$policyFiles = @(Get-ChildItem -Path $PolicyFilesRootFolder -Filter "*.policy.json" -File)
$policySetFiles = @(Get-ChildItem -Path $PolicyFilesRootFolder -Filter "*.initiative.json" -File)

$policyFileCount = $policyFiles.Count
$policySetFileCount = $policySetFiles.Count
$logArgs = @{
    Message = "Found [$policyFileCount] policy and [$policySetFileCount] initiative file(s) for [$DefinitionsDeploymentManagementGroupName]`n"
    Type    = "Information"
}
Write-AdoLogMessage @logArgs

# Validate the definitions drift control before anything is deployed
if ($UnmanagedDefinitionsAction -ne "Ignore") {
    # An empty configuration would remove every custom definition, so it is refused
    if (($policyFileCount + $policySetFileCount) -eq 0) {
        throw "No policy or initiative files found, drift control is refused to prevent removing every definition"
    }
}

# Deploying policy definitions to the management group specified by $DefinitionsDeploymentManagementGroupName
Write-AdoLogMessage -Message "Deploying policy definitions" -Type "Information"
if ($policyFileCount -eq 0) {
    Write-AdoLogMessage -Message "No policy definition files found, skipping policy definitions" -Type "Information"
}

foreach ($policyFile in $policyFiles) {
    Write-AdoLogMessage -Message " Deploying policy definition from [$($policyFile.Name)]" -Type "Information"
    $azPolicyDefinitionFromJsonArgs = @{
        PolicyFilePath      = $policyFile
        ManagementGroupName = $DefinitionsDeploymentManagementGroupName
    }
    Set-AzPolicyDefinitionFromJson @azPolicyDefinitionFromJsonArgs 1> $null
    Write-AdoLogMessage -Message " Policy definition deployment completed" -Type "Information"
}


# Deploying policy initiatives definitions to the management group specified by $DefinitionsDeploymentManagementGroupName
Write-Host ""
Write-AdoLogMessage -Message "`nDeploying policy initiatives definitions" -Type "Information"
if ($policySetFileCount -eq 0) {
    Write-AdoLogMessage -Message "No initiative files found, skipping initiatives" -Type "Information"
}


foreach ($policySetFile in $policySetFiles) {
    Write-AdoLogMessage -Message " Deploying policy initiative definition from [$($policySetFile.Name)]" -Type "Information"
    $azPolicyInitiativeDefinitionFromJsonArgs = @{
        PolicySetFilePath   = $policySetFile
        ManagementGroupName = $DefinitionsDeploymentManagementGroupName
    }
    Set-AzPolicyInitiativeDefinitionFromJson @azPolicyInitiativeDefinitionFromJsonArgs 1> $null
    Write-AdoLogMessage -Message "`nPolicy initiative definition deployment completed" -Type "Information"
}
Write-Host ""

if ([string]::IsNullOrWhiteSpace($PolicyAssignmentFilesRootFolder)) {
    if ($UnmanagedAssignmentsAction -ne "Ignore") {
        throw "UnmanagedAssignmentsAction [$UnmanagedAssignmentsAction] requires PolicyAssignmentFilesRootFolder"
    }
    Write-AdoLogMessage -Message "No PolicyAssignmentFilesRootFolder provided, skipping policy assignments" -Type "Information"
} else {

    $policyAssignmentFiles = @(Get-ChildItem -Path $PolicyAssignmentFilesRootFolder -Filter "*.parameters.jsonc" -File)
    Write-AdoLogMessage -Message "Found [$($policyAssignmentFiles.Count)] policy assignment file(s)" -Type "Information"

    foreach ($policyAssignmentFile in $policyAssignmentFiles) {
        Write-AdoLogMessage -Message "Deploying policy assignments from [$($policyAssignmentFile.Name)]" -Type "Information"
        # The deployment name shows which file it deploys, for example compliance-contoso-policies, limited to the 48 characters
        # that bicepDeployment.ps1 allows
        $deploymentDescription = ($policyAssignmentFile.BaseName -replace '\.parameters$', '') -replace '[^A-Za-z0-9._()-]', '-'
        $tenantPolicyAssignmentsParams = @{
            TemplateFile                     = $tenantPoliciesTemplate
            TemplateParameterFile            = $policyAssignmentFile.FullName
            DeploymentScope                  = "managementGroup"
            DeploymentScopeManagementGroupId = $DefinitionsDeploymentManagementGroupName
            Location                         = $DeploymentLocation
            DeploymentDescription            = $deploymentDescription.Substring(0, [System.Math]::Min(48, $deploymentDescription.Length))
        }
        . $bicepDeployment @tenantPolicyAssignmentsParams
    }

    if ($UnmanagedAssignmentsAction -ne "Ignore") {
        # Drift control runs after all deployments succeeded, as a failed run must never remove assignments
        Write-AdoLogMessage -Message "Drift control [$UnmanagedAssignmentsAction] for policy assignments that are not in the configuration" -Type "Information"

        $expectedAssignmentsByScope = @{}
        foreach ($policyAssignmentFile in $policyAssignmentFiles) {
            $policyAssignmentConfig = Get-Content -Path $policyAssignmentFile.FullName -Raw | ConvertFrom-Json
            foreach ($entry in $policyAssignmentConfig.parameters.policyAssignments.value) {
                if ([string]::IsNullOrWhiteSpace($entry.TargetScope) -or [string]::IsNullOrWhiteSpace($entry.Assignment.AssignmentName)) {
                    throw "Entry without TargetScope or AssignmentName in [$($policyAssignmentFile.Name)], drift control is not possible"
                }
                if (-not $expectedAssignmentsByScope.ContainsKey($entry.TargetScope)) {
                    $expectedAssignmentsByScope[$entry.TargetScope] = [System.Collections.Generic.List[string]]::new()
                }
                $expectedAssignmentsByScope[$entry.TargetScope].Add($entry.Assignment.AssignmentName)
            }
        }

        # An empty configuration would remove every assignment of the management groups, so it is refused
        if ($expectedAssignmentsByScope.Count -eq 0) {
            throw "No assignments found in the configuration files, drift control is refused to prevent removing every assignment"
        }

        foreach ($targetScope in $expectedAssignmentsByScope.Keys) {
            $removeAssignmentsArgs = @{
                ManagementGroupName    = $targetScope
                ExpectedAssignmentName = $expectedAssignmentsByScope[$targetScope].ToArray()
                ExcludedAssignmentName = $UnmanagedAssignmentsExclusions
                WhatIf                 = $UnmanagedAssignmentsAction -eq "Report"
            }
            Remove-AzPolicyAssignmentNotInConfig @removeAssignmentsArgs
        }
    }
}

if ($UnmanagedDefinitionsAction -ne "Ignore") {
    # Runs last: assignments must be gone before the initiatives they use can be removed, and a failed run must never
    # remove definitions
    Write-AdoLogMessage -Message "`nDrift control [$UnmanagedDefinitionsAction] for policy definitions and initiatives that are not in the configuration" -Type "Information"

    $expectedPolicyNames = @($policyFiles | ForEach-Object { (Get-Content -Path $_.FullName -Raw | ConvertFrom-Json).name })
    $expectedInitiativeNames = @($policySetFiles | ForEach-Object { (Get-Content -Path $_.FullName -Raw | ConvertFrom-Json).name })

    $removeDefinitionsArgs = @{
        ManagementGroupName    = $DefinitionsDeploymentManagementGroupName
        ExpectedPolicyName     = $expectedPolicyNames
        ExpectedInitiativeName = $expectedInitiativeNames
        ExcludedName           = $UnmanagedDefinitionsExclusions
        WhatIf                 = $UnmanagedDefinitionsAction -eq "Report"
    }
    Remove-AzPolicyDefinitionNotInConfig @removeDefinitionsArgs
}
