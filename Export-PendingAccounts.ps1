﻿###########################################################
#
# Export-PendingAccounts.ps1
#
# Copyright 2019 Michael West
#
# This script is not officially supported or endorsed by CyberArk, Inc.
#
# Licensed under the MIT License
#
###########################################################

# Change these properties for your Vault install:
$VaultAddress = "vault.example.com"

# Location of cred file to use
$CredFilePath = "user.ini"

# Location of PACLI executable
$PACLIPath = "PACLI\Pacli.exe"

# Location of output CSV file
$OutputFile = "PendingAccounts" + (Get-Date -Format "MMddyyyy-HHmm") + ".csv"

# Location of temporary processing file
$InProgressFile = "Temp-SafeFileNames.csv"

# If you use a self-signed cert on the Vault, set this to true
$AllowSelfSignedCertificates = $false

# This will cause PACLI to rotate the password of the account in the cred file automatically
$AutoChangePassword = $true

# Properties to show first in final report columns
# This is so that the output looks similar to the Pending Accounts tab
$ShowFirstProperties = "UserName", "Address", "DiscoveryPlatformType", "Dependencies", "LastPasswordSetDate", "AccountCategory"

# Properties to exclude in final report
# We use this to remove some internal properties not useful in this case
$ExcludeProperties =  "InternalName", "DeletionDate", "DeletionBy", "LastUsedDate", "LastUsedBy",
    "Size", "History", "RetrieveLock", "LockDate", "LockedBy", "FileID", "Draft", "Accessed",
    "LockedByGW", "LockedByUserId", "Safename", "Folder", "user", "vault", "sessionID", "MasterPassFolder"

# End settings

###########################################################

# The below function can be customized to meet your business needs

function SaveResults( $results ) {
    
    # Save the result as a CSV to the $OutputFile configured above
    $results | Export-Csv -Path $OutputFile -NoTypeInformation

}

###########################################################

$ErrorActionPreference = "Stop"

# Resolve relative paths
$PACLIPath = Resolve-Path -LiteralPath $PACLIPath
$CredFilePath = Resolve-Path -LiteralPath $CredFilePath

# Get username from cred file
$User = Select-String -LiteralPath $CredFilePath -Pattern "Username=(\S*)" | % { $_.Matches.Groups[1].Value }

# Helper constants
$PendingSafe = "PasswordManager_Pending"
$Vault = "vault"

# Kill PACLI if it's still around
try {
    Stop-PVPacli
} catch {}

# Connect to Vault
Import-Module PoShPACLI
Set-PVConfiguration -ClientPath $PACLIPath
Start-PVPacli
New-PVVaultDefinition -vault $Vault -address $VaultAddress -preAuthSecuredSession -trustSSC:$AllowSelfSignedCertificates
$token = Connect-PVVault -vault $Vault -user $User -logonFile $CredFilePath -autoChangePassword:$AutoChangePassword

# Clean up variable if re-running script in same terminal
$files = $false

# Does an inprogress file exist?
if (Test-Path -LiteralPath $InProgressFile) {
    # Read in list of files
    $files = Import-Csv -LiteralPath $InProgressFile
}

# Always open safe
$token | Open-PVSafe -safe $PendingSafe

# If the inprogress file is empty then pull new files
if ($files -eq $false -or $files.Count -le 0) {
    # Retrieve list of objects in safe
    $files = $token | Get-PVFileList -safe $PendingSafe -folder "Root"
    
    # Remove internal CPM .txt files
    $files = $files | Where { $_.Filename -notmatch ".*\.txt$" }

    # Export this to inprogress file
    $files | Export-Csv -LiteralPath $InProgressFile
}

# We use this later to select the properties we want with certain properties first
$SelectProperties = $ShowFirstProperties

# Add file category information to objects
try {
    foreach ($file in $files) {
        $categories = $token | Get-PVFileCategory -safe $PendingSafe -folder "Root" -file $file.Filename

        foreach ($category in $categories) {
            # Add the category as a property to the original file object
            $file | Add-Member -NotePropertyName $category.CategoryName -NotePropertyValue $category.CategoryValue

            # If this is the first time we've seen this property, add it here
            # Different objects have different properties (file categories) so we have to check each time
            if ($SelectProperties -notcontains $category.CategoryName) {
                $SelectProperties += $category.CategoryName
            }
        }

        # Remove this file from the inprogress file if we fail
        $file | Add-Member -NotePropertyName Processed -NotePropertyValue $true
        
        # Uncomment to test the resume functionality
        # throw "Test error"
    }

    # We finished everything so we can delete inprogress file
    Remove-Item $InProgressFile
} catch {
    Write-Host "Encountered error, saving current progress to $InProgressFile to resume"
    Write-Host "Error: $_"
    # Export this to inprogress file to resume later
    # Skip any files we already processed
    $files | Where { $_.Processed -ne $true } | Export-Csv -LiteralPath $InProgressFile
}

# Find dependencies and fill in some basic info
foreach ($file in $files | Where { $_.MasterPassName -ne $null }) {
    $masterpass = $files | Where { $_.Filename -eq $file.MasterPassName}

    $PropertiesToCopy = "UserName", "Dependencies", "MachineOSFamily", "OSVersion", "Domain", "OU",
    "LastPasswordSetDate", "LastLogonDate", "AccountExpirationDate", "PasswordNeverExpires", "AccountCategory"

    # Copy property info over if not null
    foreach ($PropertyName in $PropertiesToCopy) {
        $property = $masterpass | select -ExpandProperty $PropertyName
        if ($property -ne $null) {
            $file | Add-Member -NotePropertyName $PropertyName -NotePropertyValue $property
        }
    }
}


# Remove the excluded properties
# We do this last because the user might exclude properties like MasterPassName we need earlier
$files = $files | Select $SelectProperties -ExcludeProperty $ExcludeProperties

$DebugPreference = "silentlycontinue"
$VerbosePreference = "silentlycontinue"
# If we failed earlier we might not be able to disconnect, oh well
try {
    Disconnect-PVVault -vault $Vault -user $User
    Stop-PVPacli
} catch {}

# Pass result object to user-customizable function
SaveResults -results $files