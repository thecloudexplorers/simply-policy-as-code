# Role Assignment Module

## Overview

Assigns a built-in or custom Azure role to a principal at the management group the module is deployed to. It is
called by [tenantPolicies.bicep](../tenantPolicies.bicep),
which grants the system assigned identity of a policy assignment the roles it needs for remediation.

## Parameters

| Parameter          | Required | Notes                                                                                   |
| ------------------ | -------- | --------------------------------------------------------------------------------------- |
| `principalId`      | Yes      | Object id of the principal that receives the role, for example a managed identity.      |
| `roleDefinitionId` | Yes      | Guid of the role definition, exactly 36 characters. Not the full resource id of a role. |

The role definition is resolved with `tenantResourceId`, so both built-in and custom roles defined at the tenant
can be used.

## Outputs

| Output             | Notes                                |
| ------------------ | ------------------------------------ |
| `roleAssignmentId` | Resource id of the role assignment.  |

## Behaviour

- **Name:** the role assignment name is `guid(managementGroup().id, principalId, roleDefinitionId)`. Redeploying
  the same combination updates the same role assignment instead of creating a duplicate.
- **Principal type:** `principalType` is always `ServicePrincipal`. A newly created managed identity may not be
  replicated yet, and setting the type avoids a failure on the graph lookup. The module is therefore not meant for
  users or groups.
- **Scope:** the role is assigned at the management group the module is deployed to, so it is inherited by every
  subscription and resource below it. The caller selects the management group with `scope: managementGroup(...)`.

## Used for policy assignments

Policies with the `DeployIfNotExists` or `Modify` effect need a system assigned identity with roles before
remediation works. `tenantPolicies.bicep` creates one role assignment for each role in `RoleDefinitionIds` of an
assignment entry, with `assignmentPrincipalId` of the [policy assignment module](./policyAssignment.md)
as the principal. The diagnostic settings policies use:

| Role                      | Role definition id                     |
| ------------------------- | -------------------------------------- |
| Monitoring Contributor    | `749f88d5-cbae-40b8-bcfc-e573ddc772fa` |
| Log Analytics Contributor | `92aaf0da-9dab-42b6-94a3-d43ce8d16293` |

Removing a policy assignment deletes its identity but not the role assignments created for it. They stay behind
as orphaned role assignments and must be cleaned up separately.

## What-If

`principalId` is a runtime value when it comes from a policy assignment output, so What-If cannot predict the
role assignment precisely. The caller suppresses the `what-if-short-circuiting` linter diagnostic for it.

## Required permissions

The deploying identity needs `Microsoft.Authorization/roleAssignments/write` at the management group, for example
through User Access Administrator or Role Based Access Control Administrator.
