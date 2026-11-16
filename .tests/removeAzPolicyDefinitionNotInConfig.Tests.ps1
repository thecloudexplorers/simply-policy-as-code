#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    .SYNOPSIS
    Tests Remove-AzPolicyDefinitionNotInConfig.

    .DESCRIPTION
    Dot sources the function and mocks the Az.Resources cmdlets, so no Azure authentication or network access is
    required and nothing is ever removed.

    The tests cover:
    - Removal of custom definitions and initiatives that are not in the expected lists.
    - Definitions of parent management groups are never touched.
    - The exclusion list, including wildcards.
    - Initiatives are removed before policy definitions.
    - -WhatIf removes nothing.
    - A removal failure is a warning and the function continues.

    .EXAMPLE
    Invoke-Pester -Path .\.tests\removeAzPolicyDefinitionNotInConfig.Tests.ps1

    .NOTES
    Run with PowerShell 7+ (pwsh).
#>

BeforeAll {
    $functionsFolder = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\functions'
    . (Join-Path $functionsFolder 'Remove-AzPolicyDefinitionNotInConfig.ps1')

    $script:mgScope = '/providers/Microsoft.Management/managementGroups/mg-test'
    $script:parentScope = '/providers/Microsoft.Management/managementGroups/mg-parent'

    function script:New-FakeDefinition {
        param($Name, $Scope, $Kind)
        [PSCustomObject]@{
            Name = $Name
            Id   = "$Scope/providers/Microsoft.Authorization/$Kind/$Name"
        }
    }
}

Describe 'Remove-AzPolicyDefinitionNotInConfig' {
    BeforeEach {
        $script:removed = [System.Collections.Generic.List[string]]::new()

        Mock Write-AdoLogMessage {}
        Mock Get-AzPolicySetDefinition {
            @(
                New-FakeDefinition 'init-keep' $mgScope 'policySetDefinitions'
                New-FakeDefinition 'init-old' $mgScope 'policySetDefinitions'
                New-FakeDefinition 'init-parent' $parentScope 'policySetDefinitions'
            )
        }
        Mock Get-AzPolicyDefinition {
            @(
                New-FakeDefinition 'pol-keep' $mgScope 'policyDefinitions'
                New-FakeDefinition 'pol-old' $mgScope 'policyDefinitions'
                New-FakeDefinition 'team-x-pol' $mgScope 'policyDefinitions'
                New-FakeDefinition 'pol-parent' $parentScope 'policyDefinitions'
            )
        }
        Mock Remove-AzPolicySetDefinition { $script:removed.Add("set:$(($Id -split '/')[-1])") }
        Mock Remove-AzPolicyDefinition { $script:removed.Add("pol:$(($Id -split '/')[-1])") }

        $script:baseArgs = @{
            ManagementGroupName    = 'mg-test'
            ExpectedPolicyName     = @('pol-keep')
            ExpectedInitiativeName = @('init-keep')
        }
    }

    It 'removes only custom definitions of the management group that are not expected' {
        Remove-AzPolicyDefinitionNotInConfig @baseArgs

        $removed | Should -Be @('set:init-old', 'pol:pol-old', 'pol:team-x-pol')
    }

    It 'removes initiatives before policy definitions' {
        Remove-AzPolicyDefinitionNotInConfig @baseArgs

        $removed.IndexOf('set:init-old') | Should -BeLessThan $removed.IndexOf('pol:pol-old')
    }

    It 'keeps excluded names, wildcards supported, case insensitive' {
        Remove-AzPolicyDefinitionNotInConfig @baseArgs -ExcludedName @('TEAM-X-*')

        $removed | Should -Be @('set:init-old', 'pol:pol-old')
    }

    It 'removes nothing with -WhatIf' {
        Remove-AzPolicyDefinitionNotInConfig @baseArgs -WhatIf

        $removed.Count | Should -Be 0
    }

    It 'removes every custom definition when the expected lists are empty' {
        $emptyArgs = @{
            ManagementGroupName    = 'mg-test'
            ExpectedPolicyName     = @()
            ExpectedInitiativeName = @()
        }
        Remove-AzPolicyDefinitionNotInConfig @emptyArgs

        $removed.Count | Should -Be 5
    }

    It 'logs a warning and continues when a removal fails' {
        Mock Remove-AzPolicySetDefinition { throw 'in use' }

        { Remove-AzPolicyDefinitionNotInConfig @baseArgs } | Should -Not -Throw

        Should -Invoke Write-AdoLogMessage -ParameterFilter { $Type -eq 'Warning' } -Times 1 -Exactly
        $removed | Should -Be @('pol:pol-old', 'pol:team-x-pol')
    }
}
