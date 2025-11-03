<#
.SYNOPSIS
This script prompts the user for registry configuration details and automatically creates two Intune-style PowerShell scripts: 
a **Detection** script to verify whether a registry value exists and matches the expected value, and a **Remediation** script to create or correct that value if it does not. 
It also creates a project folder to store the scripts.
#>

# -------------------------
# Prompt for project & registry details
# -------------------------
$ProjectName = Read-Host "Enter the project name (used for folder name)"
$Path        = Read-Host "Enter the registry path (e.g. HKLM:\SOFTWARE\Policies\App)"
$Name        = Read-Host "Enter the registry value name (e.g. bDisableJavaScript)"
$Value       = Read-Host "Enter the expected registry value (e.g. 1 or Enabled)"
$Type        = Read-Host "Enter the registry value type (DWord, String, QWord, etc.)"

# -------------------------
# Format the value based on type
# -------------------------
switch -Regex ($Type.ToLower()) {
    "string"    { $FormattedValue = "`"$Value`"" }   # wrap in quotes
    "reg_sz"    { $FormattedValue = "`"$Value`"" }   # wrap in quotes (alias for String)
    default     { $FormattedValue = $Value }         # leave unquoted
}

# -------------------------
# Create project folder
# -------------------------
$ProjectFolder = Join-Path $ParentFolder $ProjectName
If (-Not (Test-Path $ProjectFolder)) {
    New-Item -Path $ProjectFolder -ItemType Directory -Force | Out-Null
}

# -------------------------
# Script file paths
# -------------------------
$DetectionFile   = Join-Path $ProjectFolder "$ProjectName - Detection.ps1"
$RemediationFile = Join-Path $ProjectFolder "$ProjectName - Remediation.ps1"

# -------------------------
# Detection script content
# -------------------------
$DetectionScript = @"
`$Path  = "$Path"
`$Name  = "$Name"
`$Value = $FormattedValue
`$Type  = "$Type"

`$ErrorActionPreference = "Stop"

Try {
    If (-Not (Test-Path `$Path)) {
        Write-Output "Not Compliant - Registry path not found"
        Exit 1
    }

    `$Registry = Get-ItemPropertyValue -Path `$Path -Name `$Name
    If (`$Registry -eq `$Value) {
        Write-Output "Compliant"
        Exit 0
    } 
    Else {
        Write-Output "Not Compliant - Value mismatch (Found: `$Registry, Expected: `$Value)"
        Exit 1
    }
} 
Catch {
    Write-Output "Not Compliant - `$(`$_.Exception.Message)"
    Exit 1
}
"@

# -------------------------
# Remediation script content
# -------------------------
$RemediationScript = @"
`$Path  = "$Path"
`$Name  = "$Name"
`$Value = $FormattedValue
`$Type  = "$Type"

`$ErrorActionPreference = "Stop"

Try {
    If (-Not (Test-Path `$Path)) {
        New-Item -Path `$Path -Force | Out-Null
    }

    New-ItemProperty -Path `$Path -Name `$Name -Value `$Value -PropertyType `$Type -Force | Out-Null

    Write-Output "Remediation applied successfully"
    Exit 0
}
Catch {
    Write-Output "Remediation failed - `$(`$_.Exception.Message)"
    Exit 1
}
"@

# -------------------------
# Save files
# -------------------------
Set-Content -Path $DetectionFile -Value $DetectionScript -Encoding UTF8
Set-Content -Path $RemediationFile -Value $RemediationScript -Encoding UTF8

Write-Host "✅ Scripts created in folder:`n$ProjectFolder"
Write-Host " - $DetectionFile"
Write-Host " - $RemediationFile"
