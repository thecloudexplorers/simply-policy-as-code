metadata moduleMetadata = {
  version: '2.0.0'
  author: 'Jev Suchoi'
  source: 'https://github.com/thecloudexplorers/simply-scripted'
  description: 'This bicep file assigns a policy or initiative definition to the management group it is deployed to'
}

targetScope = 'managementGroup'

@export()
@sealed()
@description('Narrows an override or resource selector to specific policies, resource types or locations')
type policySelectorType = {
  @description('What the selector matches on')
  kind: 'policyDefinitionReferenceId' | 'resourceLocation' | 'resourceType' | 'resourceWithoutLocation'

  @description('Values the selector includes')
  in: string[]?

  @description('Values the selector excludes')
  notIn: string[]?
}

@export()
@sealed()
@description('Changes the effect or the definition version of the selected policies of an assignment')
type policyOverrideType = {
  @description('What is overridden, defaults to policyEffect')
  kind: ('policyEffect' | 'definitionVersion')?

  @description('The new value, for example Audit or Deny for the policyEffect kind')
  value: string?

  @description('The policies the override applies to, no selectors applies it to the whole assignment')
  selectors: policySelectorType[]?
}

@export()
@sealed()
@description('Limits the resources a policy assignment is evaluated for')
type policyResourceSelectorType = {
  @description('Name of the resource selector')
  name: string?

  @description('The selectors that decide which resources are in scope')
  selectors: policySelectorType[]
}

@export()
@sealed()
@description('A non-compliance message, optionally for one policy of an initiative')
type policyNonComplianceMessageType = {
  @minLength(1)
  @description('The message that describes why a resource is non-compliant')
  message: string

  @description('The policy definition reference id of the initiative member the message is for, no value applies it to the whole assignment')
  policyDefinitionReferenceId: string?
}

@export()
@sealed()
@description('An Azure Policy Assignment')
type policyAssignmentType = {
  @minLength(1)
  @maxLength(24)
  @description('Policy assignment name, 24 characters is the limit at management group scope')
  AssignmentName: string

  @minLength(1)
  @maxLength(128)
  @description('Display name of the Policy Assignment')
  AssignmentDisplayName: string

  @description('Description for the Azure Policy Assignment')
  AssignmentDescription: string

  @description('Assignment enforcement mode, choose between Default or DoNotEnforce')
  AssignmentEnforcementMode: 'Default' | 'DoNotEnforce'

  @description('Custom message that describes why a resource is non-compliant with the policy or initiative definition, applies to every policy in an initiative, defaults to none')
  AssignmentNonComplianceMessage: string?

  @description('Additional non-compliance messages, for example one for each policy of an initiative, defaults to none')
  AssignmentNonComplianceMessages: policyNonComplianceMessageType[]?

  @minLength(1)
  @description('The full path name of either a policy definition or an initiative definition')
  AssignmentPolicyId: string

  @description('Version of the policy or initiative definition, for example 1.*.*, defaults to the latest version')
  AssignmentDefinitionVersion: string?

  @description('Parameter values for the assigned policy or initiative, in the form { parameterName: { value: parameterValue } }, defaults to none')
  AssignmentParameters: object?

  @description('Scopes below the assignment scope that are excluded from the assignment, defaults to none')
  AssignmentNotScopes: string[]?

  @description('Overrides of the effect or version of the selected policies, defaults to none')
  AssignmentOverrides: policyOverrideType[]?

  @description('Resource selectors that limit the resources the assignment is evaluated for, defaults to none')
  AssignmentResourceSelectors: policyResourceSelectorType[]?

  @description('Managed identity type, SystemAssigned or UserAssigned is required for policies with the DeployIfNotExists or Modify effect, defaults to None')
  AssignmentIdentityType: ('None' | 'SystemAssigned' | 'UserAssigned')?

  @description('Resource id of the user assigned managed identity, required for and only used with the UserAssigned identity type')
  AssignmentUserAssignedIdentityId: string?

  @description('Location of the policy assignment, only used with a managed identity, defaults to the deployment location')
  AssignmentLocation: string?
}

@description('The policy assignment to create')
param assignment policyAssignmentType

var identityType = assignment.?AssignmentIdentityType ?? 'None'
var userAssignedIdentityId = assignment.?AssignmentUserAssignedIdentityId ?? ''

var defaultNonComplianceMessages = empty(assignment.?AssignmentNonComplianceMessage ?? '') ? [] : [
  {
    message: assignment.?AssignmentNonComplianceMessage ?? ''
  }
]
var nonComplianceMessages = concat(defaultNonComplianceMessages, assignment.?AssignmentNonComplianceMessages ?? [])

resource policyAssignment 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: assignment.AssignmentName
  location: assignment.?AssignmentLocation ?? deployment().location
  identity: identityType == 'UserAssigned'
    ? {
        type: 'UserAssigned'
        userAssignedIdentities: {
          '${userAssignedIdentityId}': {}
        }
      }
    : {
        type: identityType
      }
  properties: {
    displayName: assignment.AssignmentDisplayName
    description: assignment.AssignmentDescription
    enforcementMode: assignment.AssignmentEnforcementMode
    nonComplianceMessages: nonComplianceMessages
    policyDefinitionId: assignment.AssignmentPolicyId
    definitionVersion: assignment.?AssignmentDefinitionVersion
    parameters: assignment.?AssignmentParameters ?? {}
    notScopes: assignment.?AssignmentNotScopes ?? []
    overrides: assignment.?AssignmentOverrides ?? []
    resourceSelectors: assignment.?AssignmentResourceSelectors ?? []
  }
}

@description('Resource Id of the policy assignment')
output assignmentId string = policyAssignment.id

@description('Principal Id of the system assigned identity, empty when no identity is assigned')
output assignmentPrincipalId string = identityType == 'SystemAssigned' ? policyAssignment.identity.principalId : ''
