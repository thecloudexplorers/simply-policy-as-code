metadata resources = {
  version: '2.0.0'
  author: 'Jev Suchoi'
  source: 'https://github.com/thecloudexplorers/simply-scripted'
  description: 'This Bicep file deploys a platform level compliance setup using Azure Policy Assignments'
}
metadata resourceSets = {}

targetScope = 'managementGroup'

import { policyAssignmentType } from './modules/policyAssignment.bicep'

@sealed()
@description('A policy assignment and the management group it is assigned to')
type policyAssignmentEntryType = {
  @minLength(1)
  @description('Id of the management group the policy or initiative is assigned to')
  TargetScope: string

  Assignment: policyAssignmentType

  @description('Guids of the Azure roles granted to the system assigned identity of the assignment at TargetScope. Requires AssignmentIdentityType SystemAssigned')
  RoleDefinitionIds: string[]?
}

@description('A collection of Azure Policy Assignments')
param policyAssignments policyAssignmentEntryType[] = []

// The scope is cut and the role definition guid is shortened, so the names stay within the 64 characters
// Azure allows for a deployment name
module platformPoliciesDeployment './modules/policyAssignment.bicep' = [
  for entry in policyAssignments: {
    name: 'policyAssignment-${take(entry.TargetScope, 20)}-${entry.Assignment.AssignmentName}'
    scope: managementGroup(entry.TargetScope)
    params: {
      assignment: entry.Assignment
    }
  }
]

// One role assignment per entry and role, so the identity of a DeployIfNotExists or Modify policy can remediate
var roleAssignmentEntries = flatten(map(range(0, length(policyAssignments)), index => map(
  policyAssignments[index].?RoleDefinitionIds ?? [],
  roleDefinitionId => {
    entryIndex: index
    roleDefinitionId: roleDefinitionId
  }
)))

module platformRoleAssignmentsDeployment './modules/roleAssignment.bicep' = [
  for roleEntry in roleAssignmentEntries: {
    name: 'roleAssignment-${take(policyAssignments[roleEntry.entryIndex].TargetScope, 12)}-${policyAssignments[roleEntry.entryIndex].Assignment.AssignmentName}-${take(roleEntry.roleDefinitionId, 8)}'
    scope: managementGroup(policyAssignments[roleEntry.entryIndex].TargetScope)
    params: {
      #disable-next-line what-if-short-circuiting
      principalId: platformPoliciesDeployment[roleEntry.entryIndex].outputs.assignmentPrincipalId
      roleDefinitionId: roleEntry.roleDefinitionId
    }
  }
]
