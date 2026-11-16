@{
    # Allow for Azure DevOps logging
    ExcludeRules = @('PSAvoidUsingWriteHost')
    Rules        = @{
        # Enforce strict casing, spacing, and formatting
        "PSAvoidUsingCmdletAliases"        = @{ Enable = $true }
        "PSUseCmdletCorrectCasing"         = @{ Enable = $true }
        "PSUseApprovedVerbs"               = @{ Enable = $true }
        # Allow for Azure DevOps logging
        "PSAvoidUsingWriteHost"            = @{ Enable = $false }
        "PSUseConsistentWhitespace"        = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $false
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $false
            CheckSeparator                          = $true
            CheckParameter                          = $false
            IgnoreAssignmentOperatorInsideHashTable = $false
        }
        "PSUseConsistentIndentation"       = @{ Enable = $true }
        "PSAvoidTrailingWhitespace"        = @{ Enable = $true }
        "PSAvoidUsingBackticks"            = @{ Enable = $true }
        "PSUseCorrectCasing"               = @{ Enable = $true }
        "PSUseSingularNouns"               = @{ Enable = $false }
        "PSProvideCommentHelp"             = @{ Enable = $true; Options = @{ Required = "ExportedFunctions" } }
        "PSAvoidUsingPositionalParameters" = @{ Enable = $true }
        # Optional rules you may enable as stricter policies
        "PSAvoidLongLines"                 = @{
            Enable            = $true
            MaximumLineLength = 180
        }
        "PSAvoidGlobalVars"                = @{ Enable = $true }
    }
}
