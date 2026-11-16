# Tenant Policies Deployment

## Overview

Assigns Azure policies and initiatives to one or more management groups. Each entry in
`policyAssignments` becomes one policy assignment, deployed at the management group named in
`TargetScope`.

## Template

- Main template: [tenantPolicies.bicep](../bicep/tenantPolicies.bicep)
- Policy assignment module:
  [policyAssignment.bicep](../bicep/modules/policyAssignment.bicep)
  ([documentation](../bicep/modules/policyAssignment.md))
- Role assignment module:
  [roleAssignment.bicep](../bicep/modules/roleAssignment.bicep)
  ([documentation](../bicep/modules/roleAssignment.md))
- Definitions, initiatives, assignments and drift control script: [tenantPolicies.ps1](../scripts/tenantPolicies.ps1)

## Expected object shape

Each entry names the management group and holds the assignment. The `Assignment` type is imported from
the child module, see its documentation for the properties, validation rules and managed identity
requirements.

```bicep
{
  TargetScope: 'mg-contoso'                         // management group id
  RoleDefinitionIds: [                              // optional, role guids for the system assigned identity
    '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
  ]
  Assignment: {
    AssignmentName: 'remediate-diag-settings'
    AssignmentDisplayName: 'Remediate diagnostic settings'
    AssignmentDescription: '...'
    AssignmentEnforcementMode: 'Default'
    AssignmentNonComplianceMessage: '...'           // optional
    AssignmentPolicyId: '/providers/Microsoft.Authorization/policySetDefinitions/...'
    AssignmentParameters: { ... }                   // optional
    AssignmentIdentityType: 'SystemAssigned'        // optional
    AssignmentLocation: 'westeurope'                // optional
  }
}
```

Both object types are sealed, so unknown or misspelled properties fail validation. The assignment
properties used to sit next to `TargetScope`, they must now be nested under `Assignment`.

`RoleDefinitionIds` grants each listed role to the system assigned identity of the assignment, at
`TargetScope`. It requires `AssignmentIdentityType: 'SystemAssigned'`, which policies with the
`DeployIfNotExists` or `Modify` effect need anyway.

## Definitions, initiatives and assignments script

[tenantPolicies.ps1](../scripts/tenantPolicies.ps1) deploys custom policy definitions
(`*.policy.json`, through `Set-AzPolicyDefinitionFromJson`) and initiatives (`*.initiative.json`, through
`Set-AzPolicyInitiativeDefinitionFromJson`) from `PolicyFilesRootFolder` to the management group in
`DefinitionsDeploymentManagementGroupName`, definitions first. A file is only updated when
`properties.metadata.version` differs from the deployed one, so raise the version when a file changes. The
pipeline flattens the configuration folders, so file names must be unique. An initiative must exist before it
is assigned.

### Definition scope

All custom policy definitions and initiatives are deployed to one single management group, the one in
`DefinitionsDeploymentManagementGroupName`. The scope is a property of the pipeline run, not of the individual
definition files, and a file cannot choose a different scope. This is intentional:

- An initiative can only reference custom policy definitions at its own scope or above. One shared scope keeps
  every reference valid.
- Assignments reference definitions with one path, for example
  `/providers/Microsoft.Management/managementGroups/<id>/providers/Microsoft.Authorization/policySetDefinitions/<name>`.
- The definition scope must be the management group that is the same as or above every management group that
  has an assignment of these definitions.

To deploy definitions to another scope, run the script again with another
`DefinitionsDeploymentManagementGroupName` and another `PolicyFilesRootFolder`.

The management group in `DefinitionsDeploymentManagementGroupName` is also where each assignment deployment runs,
that is only the scope of the ARM deployment and its record. The assignments themselves are created at the
management group in `TargetScope` of each entry in the assignment file, so assignments, unlike definitions, can
be spread over many management groups. The pipeline identity needs deployment rights at the definitions
management group and assignment rights at every `TargetScope`.

When `PolicyAssignmentFilesRootFolder` and `DeploymentLocation` are provided, the script also deploys every
`*.parameters.jsonc` file in that folder with [tenantPolicies.bicep](../bicep/tenantPolicies.bicep). The pipeline
currently deploys the assignments in a separate Bicep job and does not pass these parameters, so the script
does not deploy them twice.

## Drift control

`-UnmanagedAssignmentsAction` handles assignments that exist on a management group but are not in the
assignment files. It requires `PolicyAssignmentFilesRootFolder`.

| Value              | Behaviour                                                              |
| ------------------ | ---------------------------------------------------------------------- |
| `Ignore` (default) | No drift control.                                                      |
| `Report`           | Logs the assignments that would be removed, nothing is deleted.        |
| `Remove`           | Deletes the assignments that are not in the files.                     |

- Only management groups that appear as `TargetScope` in the files are checked, and only assignments created
  directly on them. Inherited assignments are not touched.
- Assignments carry no marker, so every assignment on those management groups that is not in the files is
  affected, including ones created by others. Start with `Report`. Use `-UnmanagedAssignmentsExclusions` to
  protect assignments that must stay. It takes assignment names, wildcards are supported (for example
  `"mcsb-*"`), and the names apply to every management group that is checked.
- It runs after all assignment deployments succeeded, and is refused when the files contain no assignments.
- Removing an assignment deletes its identity but not the role assignments created for it, they must be
  cleaned up separately.

### Definitions and initiatives

`-UnmanagedDefinitionsAction` does the same for the custom definitions and initiatives on
`DefinitionsDeploymentManagementGroupName`. It takes the same values (`Ignore`, `Report`, `Remove`) and does not
need `PolicyAssignmentFilesRootFolder`.

- A definition or initiative is kept when its `name` is in a `*.policy.json` or `*.initiative.json` file. Everything
  else that was created directly on the management group is affected, including ones created by others. Definitions
  inherited from a parent management group are never touched.
- Use `-UnmanagedDefinitionsExclusions` to protect names, wildcards are supported (for example `"team-x-*"`).
- It runs last, after the assignment drift control, because an initiative that is still assigned cannot be removed.
  Initiatives are removed before policy definitions. What Azure refuses to remove, for example because an
  assignment still uses it, is logged as a warning and skipped.
- It is refused when there are no definition or initiative files. Removing cannot be undone, start with `Report`.
