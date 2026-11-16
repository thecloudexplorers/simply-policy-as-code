<#
    .SYNOPSIS
    Writes a log entry using Azure DevOps pipeline logging commands.

    .DESCRIPTION
    This function writes a message to the Azure DevOps pipeline log.

    Information entries are written as plain messages, optionally decorated with an Azure DevOps
    formatting command such as ##[group] or ##[section].

    Warning and Error entries are emitted as ##vso[task.logissue] commands so they show up in the
    pipeline run summary. Special characters in the message are escaped so that multi-line
    messages are logged as a single issue.

    Warning entries additionally emit ##vso[task.complete result=SucceededWithIssues;] so the
    pipeline step is reported as succeeded with issues instead of plain succeeded. Error entries
    emit ##vso[task.complete result=Failed;] so the step is reported as failed, also when the script
    continues. Once an error has been logged, later warnings no longer downgrade the step result.

    An Error entry combined with -Action Stop or -Action Exit additionally terminates the script,
    see the Action parameter for the difference.

    .PARAMETER Message
    The message to log. Required for every entry, except for Information entries with FormatType
    "Endgroup", since the ##[endgroup] command does not take a message and any message is ignored.

    .PARAMETER Type
    The type of log entry. Accepts "Information", "Warning" or "Error".

    .PARAMETER FormatType
    Optional Azure DevOps formatting command applied to Information entries.
    Accepts "Group", "Warning", "Error", "Debug", "Section", "Command" or "Endgroup".

    .PARAMETER Action
    Optional, applies to Error entries only. Accepts "Continue", "Stop" or "Exit".

    "Continue", or omitted, only logs the error and the script keeps running. The step is still
    reported as failed.

    "Stop" logs the error and then throws the message as a terminating error. Use it where a caller
    can catch the exception, for example in functions or when a test expects a throw. A script that
    does not catch it ends with the pipeline task printing the exception as a second error line.

    "Exit" logs the error and then ends the script with exit code 1, without throwing. Use it in
    entry scripts, where nothing catches the error, so the error shows once. The exception does not
    unwind to an outer catch block, but finally blocks still run. Because it ends the calling script,
    avoid it in code that is dot sourced in an interactive session or called directly from a test.

    .EXAMPLE
    $logArgs = @{
        Message    = "Validating branches"
        Type       = "Information"
        FormatType = "Section"
    }
    Write-AdoLogMessage @logArgs

    .EXAMPLE
    Write-AdoLogMessage -Message "Validating branches" -Type Information -FormatType Group
    Write-AdoLogMessage -Message "Checking branch main" -Type Information
    Write-AdoLogMessage -Type Information -FormatType Endgroup

    .EXAMPLE
    $logArgs = @{
        Message = "Branch is stale"
        Type    = "Warning"
    }
    Write-AdoLogMessage @logArgs

    .EXAMPLE
    # Logs the error and keeps running, the step is reported as failed
    $logArgs = @{
        Message = "Branch protection could not be read"
        Type    = "Error"
        Action  = "Continue"
    }
    Write-AdoLogMessage @logArgs

    .EXAMPLE
    # Logs the error and throws it, a caller can catch the exception
    $logArgs = @{
        Message = "Validation failed"
        Type    = "Error"
        Action  = "Stop"
    }
    Write-AdoLogMessage @logArgs

    .EXAMPLE
    # Logs the error and ends the script with exit code 1, nothing is thrown
    $logArgs = @{
        Message = "Validation failed"
        Type    = "Error"
        Action  = "Exit"
    }
    Write-AdoLogMessage @logArgs

    .NOTES
    Version     : 1.2.0
    Author      : Jev - @devjevnl | https://www.devjev.nl
    Source      : https://github.com/thecloudexplorers/simply-scripted
    Credits     : Based on the original Write-ConsoleLogMessage by Iliyan Iliev

    .LINK
    https://learn.microsoft.com/en-us/azure/devops/pipelines/scripts/logging-commands?wt.mc_id=DT-MVP-5005327
#>
# Tracks whether an error was logged in this session, so later warnings do not downgrade a failed step
$script:AdoErrorLogged = $false

function Write-AdoLogMessage {
    [CmdletBinding()]
    param (
        [Parameter()]
        [System.String] $Message,

        [Parameter(Mandatory)]
        [ValidateSet("Information", "Warning", "Error")]
        [System.String] $Type,

        [Parameter()]
        [ValidateSet("Group", "Warning", "Error", "Debug", "Section", "Command", "Endgroup")]
        [System.String] $FormatType,

        [Parameter()]
        [ValidateSet("Continue", "Stop", "Exit")]
        [System.String] $Action
    )

    $isEndgroup = $Type -eq "Information" -and $FormatType -eq "Endgroup"

    if (-not $isEndgroup -and [System.String]::IsNullOrEmpty($Message)) {
        throw "Parameter -Message is required, it can only be omitted for Information entries with -FormatType Endgroup."
    }

    if ($isEndgroup) {
        # ##[endgroup] does not take a message
        Write-Host "##[endgroup]"
        return
    }

    if ($Type -eq "Information") {
        $formattedMessage = if ($FormatType) { "##[{0}]{1}" -f $FormatType.ToLower(), $Message } else { $Message }
        # Write-Host avoids the SilentlyContinue default of the information stream
        Write-Host $formattedMessage
        return
    }

    # Logging commands are single-line, so escape characters that would otherwise break the command
    $escapedMessage = $Message.Replace('%', '%AZP25').Replace("`r", '%0D').Replace("`n", '%0A')

    # Written to stdout as-is, Write-Warning/Write-Error would prefix the line and prevent command parsing
    Write-Host ("##vso[task.logissue type={0}]{1}" -f $Type.ToLower(), $escapedMessage)

    if ($Type -eq "Error") {
        # Marks the step as failed while still allowing the script to continue when -Action is not Stop or Exit
        $script:AdoErrorLogged = $true
        Write-Host "##vso[task.complete result=Failed;]Completed with errors"
    } elseif (-not $script:AdoErrorLogged) {
        # A logged issue alone can leave the task green, explicitly mark the task as succeeded with issues
        Write-Host "##vso[task.complete result=SucceededWithIssues;]Completed with warnings"
    }

    if ($Type -eq "Error" -and $Action -eq "Stop") {
        throw $Message
    }

    if ($Type -eq "Error" -and $Action -eq "Exit") {
        # Ends the calling script without throwing, so the pipeline task does not print the error a second time
        exit 1
    }
}
