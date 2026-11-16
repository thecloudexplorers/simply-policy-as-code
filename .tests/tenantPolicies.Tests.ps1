#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    .SYNOPSIS
    Tests the orchestration of tenantPolicies.ps1: deployment order, drift control and its safety checks.

    .DESCRIPTION
    Runs the script in a child pwsh process, because the script ends with exit code 1 on a failure, which would
    otherwise end the Pester run.

    The script loads its helpers from the RootRepoLocation parameter. The tests point it at a fixture repository that
    holds the real Write-AdoLogMessage.ps1 and stub versions of the other functions and of bicepDeployment.ps1. The
    stubs record their calls in a log file, so no Azure authentication or network access is required.

    The tests cover:
    - Policy definitions are deployed before initiatives, and assignments after both.
    - Drift control is off by default.
    - Assignment drift control and definitions drift control pass the expected names, the exclusions and -WhatIf for
      Report.
    - The definitions drift control runs last.
    - Drift control is refused without files, before anything is deployed.
    - Definitions drift control works without an assignments folder.

    .EXAMPLE
    Invoke-Pester -Path .\.tests

    .NOTES
    Run with PowerShell 7+ (pwsh), as the script requires the Core edition.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:policiesDirectory = Join-Path $repoRoot 'scripts'
    $script:scriptUnderTest = Join-Path $TestDrive 'tenantPolicies.ps1'
    # The #Requires line is removed in the copy. Loading Az.Resources is slow, nothing here uses it, and it makes
    # the process end with exit code 0 after a logged error, which hides the exit code the tests check.
    (Get-Content -Path (Join-Path $policiesDirectory 'tenantPolicies.ps1') -Raw) -replace '(?m)^#Requires -Modules Az\.Resources\r?\n', '' |
        Set-Content -Path $script:scriptUnderTest

    $script:fixtureRoot = Join-Path $TestDrive 'repo'
    $fixtureCommon = Join-Path $fixtureRoot 'scripts'
    $fixtureFunctions = Join-Path $fixtureCommon 'functions'
    New-Item -ItemType Directory -Path $fixtureFunctions -Force 1> $null

    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\functions\Write-AdoLogMessage.ps1') -Destination $fixtureFunctions

    # The stubs append one line per call to the file in the TP_CALL_LOG environment variable
    $stubs = @{
        'Set-AzPolicyDefinitionFromJson.ps1'           = @'
function Set-AzPolicyDefinitionFromJson {
    param($PolicyFilePath, $ManagementGroupName)
    Add-Content -Path $env:TP_CALL_LOG -Value "policy:$($PolicyFilePath.Name)"
}
'@
        'Set-AzPolicyInitiativeDefinitionFromJson.ps1' = @'
function Set-AzPolicyInitiativeDefinitionFromJson {
    param($PolicySetFilePath, $ManagementGroupName)
    Add-Content -Path $env:TP_CALL_LOG -Value "initiative:$($PolicySetFilePath.Name)"
}
'@
        'Remove-AzPolicyAssignmentNotInConfig.ps1'     = @'
function Remove-AzPolicyAssignmentNotInConfig {
    param($ManagementGroupName, $ExpectedAssignmentName, $ExcludedAssignmentName, [switch] $WhatIf)
    Add-Content -Path $env:TP_CALL_LOG -Value "assignmentdrift:$ManagementGroupName|$($ExpectedAssignmentName -join ',')|$($ExcludedAssignmentName -join ',')|$($WhatIf.IsPresent)"
}
'@
        'Remove-AzPolicyDefinitionNotInConfig.ps1'     = @'
function Remove-AzPolicyDefinitionNotInConfig {
    param($ManagementGroupName, $ExpectedPolicyName, $ExpectedInitiativeName, $ExcludedName, [switch] $WhatIf)
    Add-Content -Path $env:TP_CALL_LOG -Value "definitiondrift:$ManagementGroupName|$($ExpectedPolicyName -join ',')|$($ExpectedInitiativeName -join ',')|$($ExcludedName -join ',')|$($WhatIf.IsPresent)"
}
'@
    }
    foreach ($stubName in $stubs.Keys) {
        Set-Content -Path (Join-Path $fixtureFunctions $stubName) -Value $stubs[$stubName]
    }

    $bicepDeploymentStub = @'
param($TemplateFile, $TemplateParameterFile, $DeploymentScope, $DeploymentScopeManagementGroupId, $Location, $DeploymentDescription)
Add-Content -Path $env:TP_CALL_LOG -Value "assignment:$(Split-Path -Leaf $TemplateParameterFile)|$DeploymentDescription"
'@
    Set-Content -Path (Join-Path $fixtureCommon 'bicepDeployment.ps1') -Value $bicepDeploymentStub

    $script:definitionsFolder = Join-Path $TestDrive 'definitions'
    $script:assignmentsFolder = Join-Path $TestDrive 'assignments'
    $script:emptyFolder = Join-Path $TestDrive 'empty'
    New-Item -ItemType Directory -Path $definitionsFolder, $assignmentsFolder, $emptyFolder -Force 1> $null

    '{ "name": "pol-a" }' | Set-Content -Path (Join-Path $definitionsFolder 'a.policy.json')
    '{ "name": "init-a" }' | Set-Content -Path (Join-Path $definitionsFolder 'a.initiative.json')

    $assignmentFile = @'
{
  // jsonc comments are allowed in the assignment files
  "parameters": {
    "policyAssignments": {
      "value": [
        { "TargetScope": "mg-one", "Assignment": { "AssignmentName": "assign-1" } },
        { "TargetScope": "mg-one", "Assignment": { "AssignmentName": "assign-2" } }
      ]
    }
  }
}
'@
    # ConvertFrom-Json accepts the comment line in PowerShell 7
    Set-Content -Path (Join-Path $assignmentsFolder 'compliance-one.parameters.jsonc') -Value $assignmentFile

    $script:invokeScript = {
        param([hashtable] $ScriptParameters)

        $callLog = Join-Path $TestDrive "calls-$([guid]::NewGuid()).log"
        New-Item -ItemType File -Path $callLog 1> $null
        [System.Environment]::SetEnvironmentVariable('TP_CALL_LOG', $callLog)

        try {
            $arguments = @('-NoProfile', '-File', $script:scriptUnderTest, '-RootRepoLocation', $script:fixtureRoot)
            foreach ($key in $ScriptParameters.Keys) {
                $arguments += "-$key"
                $value = $ScriptParameters[$key]
                if ($value -is [array]) {
                    $arguments += ($value -join ',')
                } else {
                    $arguments += $value
                }
            }
            $output = & pwsh @arguments 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        } finally {
            [System.Environment]::SetEnvironmentVariable('TP_CALL_LOG', $null)
        }

        [PSCustomObject]@{
            Output   = $output
            ExitCode = $exitCode
            Calls    = @(Get-Content -Path $callLog)
        }
    }
}

Describe 'tenantPolicies.ps1' {
    Context 'Definitions and assignments without drift control' {
        BeforeAll {
            $parameters = @{
                PolicyFilesRootFolder                    = $definitionsFolder
                DefinitionsDeploymentManagementGroupName = 'mg-def'
                PolicyAssignmentFilesRootFolder          = $assignmentsFolder
                DeploymentLocation                       = 'westeurope'
            }
            $result = & $invokeScript $parameters
        }

        It 'completes with exit code 0' {
            $result.ExitCode | Should -Be 0
        }

        It 'deploys policies, then initiatives, then assignments, and no drift control' {
            $result.Calls | Should -Be @(
                'policy:a.policy.json'
                'initiative:a.initiative.json'
                'assignment:compliance-one.parameters.jsonc|compliance-one'
            )
        }
    }

    Context 'Drift control Report for assignments and definitions' {
        BeforeAll {
            $parameters = @{
                PolicyFilesRootFolder                    = $definitionsFolder
                DefinitionsDeploymentManagementGroupName = 'mg-def'
                PolicyAssignmentFilesRootFolder          = $assignmentsFolder
                DeploymentLocation                       = 'westeurope'
                UnmanagedAssignmentsAction               = 'Report'
                UnmanagedAssignmentsExclusions           = @('mcsb-*')
                UnmanagedDefinitionsAction               = 'Report'
                UnmanagedDefinitionsExclusions           = @('team-x-*')
            }
            $result = & $invokeScript $parameters
        }

        It 'completes with exit code 0' {
            $result.ExitCode | Should -Be 0
        }

        It 'checks the assignments of the target scope with the expected names, exclusions and WhatIf' {
            $result.Calls | Should -Contain 'assignmentdrift:mg-one|assign-1,assign-2|mcsb-*|True'
        }

        It 'checks the definitions of the definitions management group with the file names, exclusions and WhatIf' {
            $result.Calls | Should -Contain 'definitiondrift:mg-def|pol-a|init-a|team-x-*|True'
        }

        It 'runs the definitions drift control last' {
            $result.Calls[-1] | Should -BeLike 'definitiondrift:*'
            $result.Calls[-2] | Should -BeLike 'assignmentdrift:*'
        }
    }

    Context 'Definitions drift control Remove without an assignments folder' {
        BeforeAll {
            $parameters = @{
                PolicyFilesRootFolder                    = $definitionsFolder
                DefinitionsDeploymentManagementGroupName = 'mg-def'
                UnmanagedDefinitionsAction               = 'Remove'
            }
            $result = & $invokeScript $parameters
        }

        It 'completes with exit code 0' {
            $result.ExitCode | Should -Be 0
        }

        It 'does not pass WhatIf' {
            $result.Calls[-1] | Should -Be 'definitiondrift:mg-def|pol-a|init-a||False'
        }
    }

    Context 'Definitions drift control without definition files' {
        BeforeAll {
            $parameters = @{
                PolicyFilesRootFolder                    = $emptyFolder
                DefinitionsDeploymentManagementGroupName = 'mg-def'
                UnmanagedDefinitionsAction               = 'Remove'
            }
            $result = & $invokeScript $parameters
        }

        It 'ends with exit code 1' {
            $result.ExitCode | Should -Be 1
        }

        It 'logs why drift control is refused' {
            $result.Output | Should -Match 'drift control is refused to prevent removing every definition'
        }

        It 'deploys and removes nothing' {
            $result.Calls.Count | Should -Be 0
        }
    }

    Context 'Assignment drift control without an assignments folder' {
        BeforeAll {
            $parameters = @{
                PolicyFilesRootFolder                    = $definitionsFolder
                DefinitionsDeploymentManagementGroupName = 'mg-def'
                UnmanagedAssignmentsAction               = 'Report'
            }
            $result = & $invokeScript $parameters
        }

        It 'ends with exit code 1' {
            $result.ExitCode | Should -Be 1
        }

        It 'logs that PolicyAssignmentFilesRootFolder is required' {
            $result.Output | Should -Match 'requires PolicyAssignmentFilesRootFolder'
        }
    }
}
