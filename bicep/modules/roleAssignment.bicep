metadata moduleMetadata = {
  version: '1.0.0'
  author: 'Jev Suchoi'
  source: 'https://github.com/thecloudexplorers/simply-scripted'
  description: 'This bicep file assigns a built-in or custom Azure role to a principal at the management group it is deployed to'
}

targetScope = 'managementGroup'

@description('Object id of the principal that receives the role, for example the system assigned identity of a policy assignment')
param principalId string

@minLength(36)
@maxLength(36)
@description('Guid of the Azure role definition, for example 749f88d5-cbae-40b8-bcfc-e573ddc772fa for Monitoring Contributor')
param roleDefinitionId string

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, principalId, roleDefinitionId)
  properties: {
    principalId: principalId
    // A new managed identity may not be replicated yet, ServicePrincipal avoids a failure on the graph lookup
    principalType: 'ServicePrincipal'
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
  }
}

@description('Resource Id of the role assignment')
output roleAssignmentId string = roleAssignment.id
