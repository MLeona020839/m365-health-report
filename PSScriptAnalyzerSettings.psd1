@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # run.ps1 and the setup script are interactive entry points that print a human summary.
        'PSAvoidUsingWriteHost'
    )
}
