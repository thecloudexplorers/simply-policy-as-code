# simply-policy-as-code

A low-barrier way to manage Azure Policy as code. Policy definitions, initiatives and assignments live as plain JSON
files in a Git repository. One PowerShell script deploys them to your management groups.

No framework, no extra file formats, no new concepts to learn. If you can read an Azure Policy JSON file and run a
PowerShell script, you can use this.

## Why this exists

[Enterprise Policy as Code (EPAC)](https://azure.github.io/enterprise-azure-policy-as-code/) is the full-featured
answer to policy as code in Azure, and for a large organisation it is a good one. It can also feel daunting when you
start. Before the first policy is deployed you meet its own folder structure, a global settings file, environments and
selectors, a plan and deploy cycle (`Build-DeploymentPlans`, `Deploy-PolicyPlan` and `Deploy-RolesPlan`) and a long
list of concepts. Many teams recognise the moment: you want policy in Git, you open the documentation, and you close
it again because it feels like a project of its own.

That hurdle is the reason this repository exists. Policy as code should not need a learning programme first. The
goal is a way in that is:

- **Approachable.** You recognise everything you see: Azure Policy JSON, one assignment file per theme, a PowerShell
  script and a Bicep template.
- **Small enough to read.** A handful of scripts you can read in an hour and fully understand, so nothing is a black
  box and you can change it yourself.
- **Productive on day one.** Clone, adapt the names, run. No framework to learn before the first result.
- **A stepping stone.** Teams that start here get the benefits of policy as code (review, history, repeatability) and
  build the habits and the understanding to adopt something bigger later, if they ever need it.

It targets the other end of the scale from EPAC: teams that want policy in Git and a pipeline without the overhead.

|                                                           | simply-policy-as-code                                      | EPAC                                                             |
| --------------------------------------------------------- | ---------------------------------------------------------- | ---------------------------------------------------------------- |
| Goal                                                      | Get policy into Git and deployed, quickly                  | Complete policy lifecycle at enterprise scale                    |
| Learning curve                                            | Read one document                                          | Learn the framework first                                        |
| Files                                                     | Your own policy JSON files plus one assignment file format | Framework-specific structure and settings                        |
| Deployment                                                | One script, one Bicep template                             | Plan and deploy stages                                           |
| Multi-tenant, multi-environment                           | No                                                         | Yes                                                              |
| Exemption management, documentation generation, reporting | No                                                         | Yes                                                              |
| Desired state (deletes what is not in the repo)           | Assignments, definitions and initiatives, when you opt in  | Yes, for all policy resources under the root scope, configurable |
| Size                                                      | A handful of scripts you can read in an hour               | A module with many commands                                      |

The EPAC column is based on the [EPAC documentation](https://azure.github.io/enterprise-azure-policy-as-code/).
EPAC describes itself as designed for medium and large organizations, and points teams with a lower DevOps maturity
to other options. This repository is aimed at that gap.

When you outgrow this, move to EPAC. Your definitions and initiatives are standard Azure Policy JSON, so they carry over.

## What it does

- Deploys custom policy definitions (`*.policy.json`) and initiatives (`*.initiative.json`) to one management group.
  Definitions are deployed before initiatives, so initiatives can reference them.
- Only updates a definition when `properties.metadata.version` changes. No version change, no deployment.
- Deploys policy assignments (`*.parameters.jsonc`) with a Bicep template, each to the management group named in the
  file. Assignments support effect overrides, non-compliance scopes, parameters, system or user-assigned identities
  and role assignments for those identities.
- Optional drift control: report, or remove, assignments on the target management groups, and custom definitions and
  initiatives on the definitions management group, that are not in the files. An exclusion list protects what must stay.
- Readable deployment names and log output, built for Azure DevOps pipelines but fine in a terminal.

## What it deliberately does not do

- No exemptions, no documentation or compliance report generation.
- No multi-tenant or multi-environment handling. One run is one tenant.
- No removal of anything by default. Drift control is opt-in, and has no marker, so it affects everything that is not in
  the files unless you exclude it.
- No planning step. It deploys, with the version check as the only safeguard.

Keeping this list short is the point. Every feature added here moves it closer to EPAC.

## Repository layout

```
bicep/                      tenantPolicies.bicep and its modules
configuration/
  policy-definitions/       *.policy.json and *.initiative.json
  policy-assignments/       *.parameters.jsonc, one file per theme
docs/                       tenantPolicies.md, the full reference
.tests/                     Pester tests, run with: Invoke-Pester -Path .\.tests
scripts/
  tenantPolicies.ps1        the entry point
  bicepDeployment.ps1       deploys a Bicep template at a management group
  functions/                one function per file
```

The examples in `configuration/` use the fictional organisation Contoso with the management groups `mg-contoso` and
`mg-sandbox`. Replace the names and the placeholder subscription ids with your own.

## Prerequisites

- PowerShell 7 (`pwsh`)
- The `Az.Resources` module
- The [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install)
- An identity with rights to deploy at the definitions management group and to assign policy at every `TargetScope`
  (for example Resource Policy Contributor, plus User Access Administrator or Owner when assignments get roles)

## Quick start

```powershell
Connect-AzAccount

$params = @{
    RootRepoLocation                         = "C:\repos\simply-policy-as-code"
    PolicyFilesRootFolder                    = "C:\repos\simply-policy-as-code\configuration\policy-definitions"
    DefinitionsDeploymentManagementGroupName = "mg-contoso"
    PolicyAssignmentFilesRootFolder          = "C:\repos\simply-policy-as-code\configuration\policy-assignments"
    DeploymentLocation                       = "westeurope"
}
.\scripts\tenantPolicies.ps1 @params
```

Leave out `PolicyAssignmentFilesRootFolder` to deploy only definitions and initiatives. Add
`UnmanagedAssignmentsAction = "Report"` and `UnmanagedDefinitionsAction = "Report"` to see what is not in the files
before you ever use `Remove`.

## Day-to-day workflow

1. Change or add a JSON file in `configuration/`.
2. Raise `properties.metadata.version` when you change a definition or initiative.
3. Open a pull request, get it reviewed.
4. Run the script from your pipeline after merge.

## Things to know

- All definitions and initiatives of a run go to one management group. Assignments can target any management group.
- Renaming or deleting a definition file does not remove the old definition unless `UnmanagedDefinitionsAction` is
  `Remove`.
- Azure does not allow changing the policy definition of an existing assignment. If you rename an initiative, delete
  the old assignment and let the script recreate it.
- Assignment names are limited to 24 characters at management group scope.
- Policy files are read from a flat folder, so file names must be unique.

See [docs/tenantPolicies.md](docs/tenantPolicies.md) for the assignment file format and all parameters.
