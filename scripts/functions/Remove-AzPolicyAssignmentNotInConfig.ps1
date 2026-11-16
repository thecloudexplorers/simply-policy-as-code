#requires -Modules Az.Resources

# The logger is loaded here when the caller has not loaded it yet. The guard keeps the logger of the caller intact,
# because loading it again would reset the error state that the logger keeps.
if (-not (Get-Command -Name Write-AdoLogMessage -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Write-AdoLogMessage.ps1')
}

<#
    .SYNOPSIS
    Removes the policy assignments of a management group that are not part of the configuration.

    .DESCRIPTION
    Lists the policy assignments that are created directly on a management group, and removes every
    assignment whose name is not in the list of expected assignment names. Assignments that the
    management group only inherits from a parent are never touched.

    There is no marker on the assignments, so every assignment on the management group that is not in
    the expected list is removed, regardless of who created it.

    Use -WhatIf to only log the assignments that would be removed.

    The function logs through Write-AdoLogMessage. Dot sourcing this file loads Write-AdoLogMessage.ps1
    from the same folder, unless the caller has already loaded it.

    .PARAMETER ManagementGroupName
    The name of the management group to clean up.

    .PARAMETER ExpectedAssignmentName
    The names of the assignments that must be kept on the management group. An empty list removes all
    assignments of the management group.

    .PARAMETER ExcludedAssignmentName
    Optional. Names of assignments that are never removed, even though they are not in the expected list, for
    example assignments that are created by another team. Wildcards are supported, for example "mcsb-*".
    Matching is case insensitive.

    .EXAMPLE
    $removeArgs = @{
        ManagementGroupName    = "mg-platform"
        ExpectedAssignmentName = @("diag-loganalytics-weu", "diag-loganalytics-gwc")
        ExcludedAssignmentName = @("mcsb-*")
    }
    Remove-AzPolicyAssignmentNotInConfig @removeArgs -WhatIf

    .NOTES
    Version     : 1.0.0
    Author      : Jev - @devjevnl | https://www.devjev.nl
    Source      : https://github.com/thecloudexplorers/simply-scripted

    Removing an assignment deletes its system assigned identity as well. The role assignments of that
    identity are not removed by this function.

    .LINK
    https://learn.microsoft.com/en-us/powershell/module/az.resources/remove-azpolicyassignment?wt.mc_id=DT-MVP-5005327
#>
function Remove-AzPolicyAssignmentNotInConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.String] $ManagementGroupName,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.String[]] $ExpectedAssignmentName,

        [Parameter()]
        [System.String[]] $ExcludedAssignmentName = @()
    )

    $managementGroupScope = "/providers/Microsoft.Management/managementGroups/$ManagementGroupName"

    Write-Host ""
    $logArgs = @{
        Message = "Looking for policy assignments on [$ManagementGroupName] that are not in the configuration"
        Type    = "Information"
    }
    Write-AdoLogMessage @logArgs

    # Get-AzPolicyAssignment also returns the assignments inherited from parent scopes, so those are filtered out
    $inScopeAssignments = @(Get-AzPolicyAssignment -Scope $managementGroupScope)
    $existingAssignments = @($inScopeAssignments | Where-Object { $_.Scope -eq $managementGroupScope })
    $notExpectedAssignments = @($existingAssignments | Where-Object { $ExpectedAssignmentName -notcontains $_.Name })

    $unmanagedAssignments = [System.Collections.Generic.List[object]]::new()
    foreach ($notExpectedAssignment in $notExpectedAssignments) {
        $assignmentName = $notExpectedAssignment.Name
        $isExcluded = $false
        foreach ($excludedName in $ExcludedAssignmentName) {
            if ($assignmentName -like $excludedName) {
                $isExcluded = $true
                break
            }
        }

        if ($isExcluded) {
            $logArgs = @{
                Message = "Keeping policy assignment [$assignmentName] on [$ManagementGroupName], it is in the exclusion list"
                Type    = "Information"
            }
            Write-AdoLogMessage @logArgs
        } else {
            $unmanagedAssignments.Add($notExpectedAssignment)
        }
    }

    $logArgs = @{
        Message = "Found [$($existingAssignments.Count)] assignment(s) on [$ManagementGroupName], [$($unmanagedAssignments.Count)] to remove"
        Type    = "Information"
    }
    Write-AdoLogMessage @logArgs

    foreach ($unmanagedAssignment in $unmanagedAssignments) {
        $logArgs = @{
            Message = "Removing policy assignment [$($unmanagedAssignment.Name)] from [$ManagementGroupName]"
            Type    = "Information"
        }
        Write-AdoLogMessage @logArgs

        if ($PSCmdlet.ShouldProcess($unmanagedAssignment.Name, "Remove-AzPolicyAssignment")) {
            Remove-AzPolicyAssignment -Id $unmanagedAssignment.Id 1> $null
        }
    }
}
