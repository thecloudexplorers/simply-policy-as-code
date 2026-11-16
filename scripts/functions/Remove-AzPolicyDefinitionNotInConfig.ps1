#requires -Modules Az.Resources

# The logger is loaded here when the caller has not loaded it yet. The guard keeps the logger of the caller intact,
# because loading it again would reset the error state that the logger keeps.
if (-not (Get-Command -Name Write-AdoLogMessage -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Write-AdoLogMessage.ps1')
}

<#
    .SYNOPSIS
    Removes the custom policy initiatives and policy definitions of a management group that are not part of the
    configuration.

    .DESCRIPTION
    Lists the custom initiatives and policy definitions that are created directly on a management group. Every one
    that is not in the expected lists and not in the exclusion list is removed. Definitions that the management group
    only inherits from a parent are never touched.

    The initiatives are removed first, then the policy definitions, because a policy definition that is still part of an
    initiative cannot be removed. A definition or initiative that Azure refuses to remove, for example because an
    assignment still uses it, is logged as a warning and skipped. The function does not fail on it.

    There is no marker on the definitions, so every custom definition on the management group that is not in the
    expected lists is removed, regardless of who created it. Use the exclusion list to protect definitions.

    Use -WhatIf to only log what would be removed.

    The function logs through Write-AdoLogMessage. Dot sourcing this file loads Write-AdoLogMessage.ps1
    from the same folder, unless the caller has already loaded it.

    .PARAMETER ManagementGroupName
    The name of the management group to clean up.

    .PARAMETER ExpectedPolicyName
    The names of the policy definitions that must be kept. An empty list means that every custom policy definition is
    removed.

    .PARAMETER ExpectedInitiativeName
    The names of the initiatives that must be kept. An empty list means that every custom initiative is removed.

    .PARAMETER ExcludedName
    Optional. Names that are never removed, even though they are not in the expected lists, for example definitions
    that are created by another team. Wildcards are supported, for example "contoso-legacy-*". Matching is case
    insensitive.

    .EXAMPLE
    $removeArgs = @{
        ManagementGroupName    = "mg-contoso"
        ExpectedPolicyName     = @("contoso-audit-tag-on-subscription")
        ExpectedInitiativeName = @("contoso-required-tags")
        ExcludedName           = @("team-x-*")
    }
    Remove-AzPolicyDefinitionNotInConfig @removeArgs -WhatIf

    .NOTES
    Version     : 1.0.0
    Author      : Jev - @devjevnl | https://www.devjev.nl
    Source      : https://github.com/thecloudexplorers/simply-scripted

    Removing a definition cannot be undone.

    .LINK
    https://learn.microsoft.com/en-us/powershell/module/az.resources/remove-azpolicydefinition?wt.mc_id=DT-MVP-5005327

    .LINK
    https://learn.microsoft.com/en-us/powershell/module/az.resources/remove-azpolicysetdefinition?wt.mc_id=DT-MVP-5005327
#>
function Remove-AzPolicyDefinitionNotInConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [System.String] $ManagementGroupName,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.String[]] $ExpectedPolicyName,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.String[]] $ExpectedInitiativeName,

        [Parameter()]
        [System.String[]] $ExcludedName = @()
    )

    $managementGroupScope = "/providers/Microsoft.Management/managementGroups/$ManagementGroupName"

    # Get-AzPolicyDefinition and Get-AzPolicySetDefinition also return the definitions of the parent scopes,
    # so only the ones with an id below this management group are kept
    $scopeFilter = { $_.Id -like "$managementGroupScope/providers/*" }

    $kinds = @(
        @{
            Label    = "initiative"
            Expected = $ExpectedInitiativeName
            Existing = @(Get-AzPolicySetDefinition -ManagementGroupName $ManagementGroupName -Custom | Where-Object $scopeFilter)
            Remove   = { param($id) Remove-AzPolicySetDefinition -Id $id -Force -ErrorAction Stop 1> $null }
        },
        @{
            Label    = "policy definition"
            Expected = $ExpectedPolicyName
            Existing = @(Get-AzPolicyDefinition -ManagementGroupName $ManagementGroupName -Custom | Where-Object $scopeFilter)
            Remove   = { param($id) Remove-AzPolicyDefinition -Id $id -Force -ErrorAction Stop 1> $null }
        }
    )

    foreach ($kind in $kinds) {
        $label = $kind.Label
        Write-Host ""
        $logArgs = @{
            Message = "Looking for ${label}s on [$ManagementGroupName] that are not in the configuration"
            Type    = "Information"
        }
        Write-AdoLogMessage @logArgs

        $toRemove = [System.Collections.Generic.List[object]]::new()
        foreach ($existing in $kind.Existing) {
            if ($kind.Expected -contains $existing.Name) {
                continue
            }

            $isExcluded = $false
            foreach ($excluded in $ExcludedName) {
                if ($existing.Name -like $excluded) {
                    $isExcluded = $true
                    break
                }
            }

            if ($isExcluded) {
                $logArgs = @{
                    Message = "Keeping $label [$($existing.Name)] on [$ManagementGroupName], it is in the exclusion list"
                    Type    = "Information"
                }
                Write-AdoLogMessage @logArgs
            } else {
                $toRemove.Add($existing)
            }
        }

        $logArgs = @{
            Message = "Found [$($kind.Existing.Count)] ${label}(s) on [$ManagementGroupName], [$($toRemove.Count)] to remove"
            Type    = "Information"
        }
        Write-AdoLogMessage @logArgs

        foreach ($item in $toRemove) {
            $logArgs = @{
                Message = "Removing $label [$($item.Name)] from [$ManagementGroupName]"
                Type    = "Information"
            }
            Write-AdoLogMessage @logArgs

            if ($PSCmdlet.ShouldProcess($item.Name, "Remove $label")) {
                try {
                    & $kind.Remove $item.Id
                } catch {
                    $logArgs = @{
                        Message = "Could not remove $label [$($item.Name)], it is probably still in use: $($_.Exception.Message)"
                        Type    = "Warning"
                    }
                    Write-AdoLogMessage @logArgs
                }
            }
        }
    }
}
