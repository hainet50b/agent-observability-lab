@{
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSUseBOMForUnicodeEncodedFile'
        # internal helpers use approved state-changing verbs (Remove-*, etc.) but
        # gate via interactive confirm / non-TTY abort, not -WhatIf/-Confirm
        'PSUseShouldProcessForStateChangingFunctions'
    )
    Rules = @{
        PSUseConsistentIndentation = @{
            Enable          = $true
            Kind            = 'space'
            IndentationSize = 4
        }
    }
}
