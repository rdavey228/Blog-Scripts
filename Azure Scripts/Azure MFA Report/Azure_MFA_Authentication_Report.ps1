<#
.SYNOPSIS
    Generate an HTML report showing Azure AD authentication methods for users in a specified group.

.DESCRIPTION
    Connects to Microsoft Graph, retrieves the members of a specified Azure AD group,
    queries each user's authentication methods (using the beta endpoint for methods),
    evaluates MFA posture, finds stale methods (not used within $StaleDays),
    builds tooltips and friendly names, aggregates results, and writes an HTML
    report with JavaScript-based filtering.

.NOTES
    - This file only includes comments and documentation added for readability.
    - No script logic has been changed.
    - Requirements (modules): Microsoft.Graph.Authentication, Microsoft.Graph.Users
    - Required Graph permissions (consent): User.Read.All, Group.Read.All, Directory.Read.All
#>

<#
Requires:
Install-Module Microsoft.Graph.Authentication -Force
Install-Module Microsoft.Graph.Users -Force
#>

# =========================
# CONFIG
# =========================
# GroupId: the Azure AD group to examine
$GroupId = "5419e8c6-1b2e-47d2-bb4c-318aa8946c08"
# ScriptVersion: human-readable version for the report
$ScriptVersion = "1.11.1"   # Patch version incremented
# StaleDays: how many days before a method is considered stale
$StaleDays = 90
# =========================

# Connect to Microsoft Graph with required scopes
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes "User.Read.All", "Group.Read.All", "Directory.Read.All" | Out-Null

# Retrieve the group display name for use in the report
Write-Host "Retrieving group name…" -ForegroundColor Cyan
$GroupInfo = Get-MgGroup -GroupId $GroupId -Property DisplayName -ErrorAction Stop
$GroupName = $GroupInfo.DisplayName
Write-Host "Selected Group: $GroupName" -ForegroundColor Green

Write-Host "Retrieving users from group…" -ForegroundColor Cyan

# =========================
# RETRIEVE USERS FROM GROUP (paging)
# =========================
# Build the initial REST URI to fetch members with selected fields.
$Users = @()
$Uri = "https://graph.microsoft.com/v1.0/groups/$GroupId/members?`$select=id,displayName,userPrincipalName,mail"
do {
    # Invoke-MgGraphRequest used to handle paging and raw REST call
    $Response = Invoke-MgGraphRequest -Uri $Uri -Method GET -ErrorAction Stop
    foreach ($m in $Response.value) {
        # Filter only actual user objects (members can include service principals, groups, etc.)
        if ($m.'@odata.type' -eq '#microsoft.graph.user') {
            $Users += [pscustomobject]@{
                displayName       = $m.displayName
                userPrincipalName = $m.userPrincipalName
                id                = $m.id
            }
        }
    }
    # Follow nextLink if there are more pages
    $Uri = $Response.'@odata.nextLink'
} while ($Uri)

# Summarize how many users were collected
$Total = $Users.Count
Write-Host "Users found: $Total" -ForegroundColor Green
if ($Total -eq 0) { exit }

Write-Host "Retrieving authentication methods for each user..." -ForegroundColor Cyan

# =========================
# HELPERS
# =========================

# Format dates to UK (dd/MM/yyyy) for display
function Format-DateUK { 
    param($dt) 
    if ($null -eq $dt -or $dt -eq "") { return $null } 
    return (Get-Date $dt -Format "dd/MM/yyyy") 
}

# Calculate the cutoff datetime for stale methods
$StaleCutoff = (Get-Date).AddDays(-$StaleDays)

# Provide friendly names for the Graph '@odata.type' strings so the report is readable
$FriendlyNames = @{
    "#microsoft.graph.passwordAuthenticationMethod"                 = "Password"
    "#microsoft.graph.emailAuthenticationMethod"                    = "Email"
    "#microsoft.graph.phoneAuthenticationMethod"                    = "Phone"
    "#microsoft.graph.temporaryAccessPassAuthenticationMethod"      = "TAP"
    "#microsoft.graph.fido2AuthenticationMethod"                    = "Passkeys (FIDO2)"
    "#microsoft.graph.windowsHelloForBusinessAuthenticationMethod"  = "Windows Hello"
    "#microsoft.graph.microsoftAuthenticatorAuthenticationMethod"   = "Authenticator – Push/OATH"
    "#microsoft.graph.passwordlessMicrosoftAuthenticatorAuthenticationMethod" = "Authenticator – Passwordless"
}

# Get-DeviceName: picks a good display name for a device/auth method object
function Get-DeviceName {
    param($m)
    $deviceProps = @($m.deviceDisplayName,$m.displayName,$m.deviceName,$m.deviceTag,$m.model,$m.description)
    $name = ($deviceProps | Where-Object { ($_ -is [string]) -and $_.Trim() -ne "" } | Select-Object -First 1)
    if (-not $name) {
        if ($m.phoneNumber) { return $m.phoneNumber }
        if ($m.emailAddress) { return $m.emailAddress }
        return "(Unknown device)"
    }
    return $name
}

# Build-TooltipText: create an HTML-safe tooltip string for a collection of methods
function Build-TooltipText($methods) {
    if (-not $methods -or $methods.Count -eq 0) { return "No methods" }
    $items = @()
    foreach ($m in $methods) {
        $name = Get-DeviceName $m
        $last = if ($m.lastUsedDateTime) { Format-DateUK $m.lastUsedDateTime } else { "Never used" }
        $items += "$name (Last Used: $last)"
    }
    $items = $items | Select-Object -Unique
    $joined = $items -join "`n"
    return ([System.Net.WebUtility]::HtmlEncode($joined) -replace "&#x0A;","&#10;" -replace "`n","&#10;")
}

# =========================
# MAIN: Iterate users and collect auth method data
# =========================
$Results = @()
$index = 0

foreach ($User in $Users) {
    # Update progress UI
    $index++
    Write-Progress -Activity "Processing users ($index/$Total)..." `
                   -Status "$($User.DisplayName)" `
                   -PercentComplete (($index / $Total) * 100)

    Try {
        # Beta endpoint is used to get authentication methods for a user
        $Auth = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/users/$($User.Id)/authentication/methods" -OutputType PSObject
        $Auth = $Auth.value
    } Catch {
        Write-Warning "Failed to retrieve auth methods for $($User.DisplayName)"
        $Auth = @()
    }

    # Initialize method buckets for each friendly key
    $Methods = @{ }
    foreach ($key in $FriendlyNames.Keys) { $Methods[$key] = $Auth | Where-Object { $_.'@odata.type' -eq $key } }

    # =========================
    # Evaluate MFA posture
    # =========================
    # Count non-password methods to determine if user has MFA
    $NonPasswordCount = ($Methods.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum - ($Methods["#microsoft.graph.passwordAuthenticationMethod"].Count)
    $NoMFA = ($NonPasswordCount -eq 0)

    # SMS-only detection (phone exists but other strong methods do not)
    $SmsOnly = ($Methods["#microsoft.graph.phoneAuthenticationMethod"].Count -gt 0) -and
               ($Methods["#microsoft.graph.fido2AuthenticationMethod"].Count -eq 0) -and
               ($Methods["#microsoft.graph.microsoftAuthenticatorAuthenticationMethod"].Count -eq 0) -and
               ($Methods["#microsoft.graph.passwordlessMicrosoftAuthenticatorAuthenticationMethod"].Count -eq 0) -and
               ($Methods["#microsoft.graph.windowsHelloForBusinessAuthenticationMethod"].Count -eq 0)

    # Strong MFA detection (FIDO2, Authenticator push/OATH, passwordless, Windows Hello)
    $HasStrong = ($Methods["#microsoft.graph.fido2AuthenticationMethod"].Count -gt 0) -or
                 ($Methods["#microsoft.graph.microsoftAuthenticatorAuthenticationMethod"].Count -gt 0) -or
                 ($Methods["#microsoft.graph.passwordlessMicrosoftAuthenticatorAuthenticationMethod"].Count -gt 0) -or
                 ($Methods["#microsoft.graph.windowsHelloForBusinessAuthenticationMethod"].Count -gt 0)

    $MFAStatus = if ($NoMFA) { "No MFA" } elseif ($SmsOnly) { "SMS-only (High Risk)" } elseif ($HasStrong) { "Has Strong MFA" } else { "Other MFA (Email/TAP/etc.)" }

    # =========================
    # Identify stale methods (not used since $StaleCutoff)
    # =========================
    $staleList = @()
    foreach ($m in $Auth) {
        if ($m.lastUsedDateTime) {
            $ldt = Get-Date $m.lastUsedDateTime -ErrorAction SilentlyContinue
            if ($ldt -and $ldt -lt $StaleCutoff) {
                $typeKey = $m.'@odata.type'
                $typeFriendly = if ($typeKey -and $FriendlyNames.ContainsKey($typeKey)) { [string]$FriendlyNames[$typeKey] } else { "Other" }
                $deviceName = Get-DeviceName $m
                $lastUsedDate = Format-DateUK $m.lastUsedDateTime
                $staleList += "$typeFriendly – $deviceName (Last Used: $lastUsedDate)"
            }
        }
    }
    $StaleMethodsRaw = ($staleList | Select-Object -Unique) -join "`n"
    $StaleMethodsTooltip = [System.Net.WebUtility]::HtmlEncode($StaleMethodsRaw) -replace "&#x0A;","&#10;" -replace "`n","&#10;"
    $StaleMethods = if ($StaleMethodsRaw) { $StaleMethodsRaw -replace "`n","<br>" } else { "" }

    # =========================
    # Determine last used method for display
    # =========================
    $LastUsed = $Auth | Where-Object { $_.lastUsedDateTime } | Sort-Object { Get-Date $_.lastUsedDateTime } -Descending | Select-Object -First 1
    if ($LastUsed) {
        $typeKeyLU = $LastUsed.'@odata.type'
        $LastUsedName = if ($typeKeyLU -and $FriendlyNames.ContainsKey($typeKeyLU)) { [string]$FriendlyNames[$typeKeyLU] } else { "Other" }
        $LastUsedDevice = Get-DeviceName $LastUsed
        $LastUsedDate = Format-DateUK $LastUsed.lastUsedDateTime
        $LastUsedTooltip = "$LastUsedName – $LastUsedDevice (Last Used: $LastUsedDate)"
        $LastUsedDisplay = $LastUsedTooltip
    } else {
        $LastUsedTooltip = "No methods used"
        $LastUsedDisplay = "None"
    }

    # =========================
    # Aggregate results into a PSCustomObject for reporting
    # =========================
    $Results += [PSCustomObject]@{
        DisplayName = $User.DisplayName
        UserPrincipalName = $User.UserPrincipalName
        PasswordCount = $Methods["#microsoft.graph.passwordAuthenticationMethod"].Count
        EmailCount = $Methods["#microsoft.graph.emailAuthenticationMethod"].Count
        EmailTooltip = Build-TooltipText $Methods["#microsoft.graph.emailAuthenticationMethod"]
        PhoneCount = $Methods["#microsoft.graph.phoneAuthenticationMethod"].Count
        PhoneTooltip = Build-TooltipText $Methods["#microsoft.graph.phoneAuthenticationMethod"]
        TAPCount = $Methods["#microsoft.graph.temporaryAccessPassAuthenticationMethod"].Count
        TAPTooltip = Build-TooltipText $Methods["#microsoft.graph.temporaryAccessPassAuthenticationMethod"]
        FIDO2Count = $Methods["#microsoft.graph.fido2AuthenticationMethod"].Count
        FIDO2Tooltip = Build-TooltipText $Methods["#microsoft.graph.fido2AuthenticationMethod"]
        WindowsHelloCount = $Methods["#microsoft.graph.windowsHelloForBusinessAuthenticationMethod"].Count
        WindowsHelloTooltip = Build-TooltipText $Methods["#microsoft.graph.windowsHelloForBusinessAuthenticationMethod"]
        AuthPushCount = $Methods["#microsoft.graph.microsoftAuthenticatorAuthenticationMethod"].Count
        AuthPushTooltip = Build-TooltipText $Methods["#microsoft.graph.microsoftAuthenticatorAuthenticationMethod"]
        AuthPwdLessCount = $Methods["#microsoft.graph.passwordlessMicrosoftAuthenticatorAuthenticationMethod"].Count
        AuthPwdLessTooltip = Build-TooltipText $Methods["#microsoft.graph.passwordlessMicrosoftAuthenticatorAuthenticationMethod"]
        MFAStatus = $MFAStatus
        StaleMethods = $StaleMethods
        StaleMethodsTooltip = $StaleMethodsTooltip
        LastUsedDisplay = $LastUsedDisplay
        LastUsedTooltip = $LastUsedTooltip
    }
}

# =========================
# BUILD HTML REPORT
# =========================

# Ensure Reports folder exists
$CsvFolder = ".\Reports"
if (-not (Test-Path $CsvFolder)) { New-Item -ItemType Directory -Path $CsvFolder | Out-Null }

# Build a sanitized HTML filename using the group name and a timestamp
$HtmlFile = "$CsvFolder\AuthMethods_$($GroupName -replace '[^a-zA-Z0-9]', '_')_$(Get-Date -Format yyyyMMdd_HHmm).html"

# HTML header (CSS and report header info)
$HtmlHeader = @"
<style>
body { font-family: Arial; margin: 20px; }
h2 { color: #2F5496; }
table { border-collapse: collapse; width: 100%; font-size: 13px; }
th, td { border: 1px solid #ccc; padding: 6px; text-align: left; }
th { background: #2F5496; color: white; }
tr:nth-child(even) { background: #f2f2f2; }
.present { background-color: #d4edda; }
.missing { background-color: #f8d7da; }
.flag-no-mfa { background-color: #ffe6e6; }
.flag-sms-only { background-color: #fff3cd; }
.flag-ok { background-color: #e6ffed; }
.stale { color: #b85c00; font-weight: bold; }
.small { font-size:11px; color:#444; }
.filter-btn { padding:6px 10px; border:1px solid #666; margin-right:5px; cursor:pointer; border-radius:5px; background:#eee; font-size:12px; }
.filter-btn:hover { background:#ddd; }
</style>
<h2>Azure Authentication Methods Report</h2>
<b>Group:</b> $GroupName<br>
<b>Generated:</b> $(Get-Date)<br>
<b>Script version:</b> $ScriptVersion<br><br>
<div id='mfa-buttons-container'></div>
"@

# Build table rows from the $Results collection
$HtmlRows = $Results | ForEach-Object {
    $row = "<tr><td class='small'>$($_.DisplayName)</td><td class='small'>$($_.UserPrincipalName)</td>"
    $cols = @(
        @{Count=$_.PasswordCount; Tooltip=""},  # No tooltip
        @{Count=$_.EmailCount; Tooltip=$_.EmailTooltip},
        @{Count=$_.PhoneCount; Tooltip=$_.PhoneTooltip},
        @{Count=$_.TAPCount; Tooltip=$_.TAPTooltip},
        @{Count=$_.FIDO2Count; Tooltip=$_.FIDO2Tooltip},
        @{Count=$_.WindowsHelloCount; Tooltip=$_.WindowsHelloTooltip},
        @{Count=$_.AuthPushCount; Tooltip=$_.AuthPushTooltip},
        @{Count=$_.AuthPwdLessCount; Tooltip=$_.AuthPwdLessTooltip}
    )
    for ($i=0; $i -lt $cols.Count; $i++) {
        $c=$cols[$i]
        $count = if ($c.Count) { $c.Count } else { 0 }
        $tooltip = if ($c.Tooltip) { $c.Tooltip } else { "No methods" }
        $class = if ($count -gt 0) { 'present' } else { 'missing' }
        $emoji = if ($count -gt 0) { '✅' } else { '❌' }
        $row += "<td class='$class' title='$tooltip'>$emoji ($count)</td>"
    }
    $mfaEmoji = switch ($_.MFAStatus) { "No MFA" {"❌"} "SMS-only (High Risk)" {"⚠️"} default {"✅"} }
    $mfaClass = switch ($_.MFAStatus) { "No MFA" {"flag-no-mfa"} "SMS-only (High Risk)" {"flag-sms-only"} default {"flag-ok"} }
    $row += "<td class='small $mfaClass' title='MFA Status'>$mfaEmoji $($_.MFAStatus)</td>"
    $row += "<td class='small' title='$($_.StaleMethodsTooltip)'>$($_.StaleMethods)</td>"
    $row += "<td class='small' title='$($_.LastUsedTooltip)'>$($_.LastUsedDisplay)</td>"
    $row += "</tr>"
    $row
}

# Table structure and column headers
$HtmlBody = "<table id='authTable'><thead><tr>
<th>Display Name</th>
<th>UserPrincipalName</th>
<th>Password</th>
<th>Email</th>
<th>Phone</th>
<th>TAP</th>
<th>Passkeys (FIDO2)</th>
<th>Windows Hello</th>
<th>Authenticator – Push/OATH</th>
<th>Authenticator – Passwordless</th>
<th>MFA Status</th>
<th>Stale Methods</th>
<th>Last Used Method</th>
</tr></thead><tbody>"
$HtmlBody += $HtmlRows -join "`n"
$HtmlBody += "</tbody></table>"

# Footer JavaScript that adds DataTables and filter buttons for interactivity
# (Filter buttons include No MFA, SMS-only, Strong MFA, Passwordless Ready, Phish Resistant, Reset)
$HtmlFooter = @'
<script src="https://code.jquery.com/jquery-3.7.1.min.js"></script>
<script src="https://cdn.datatables.net/1.13.6/js/jquery.dataTables.min.js"></script>
<link rel="stylesheet" href="https://cdn.datatables.net/1.13.6/css/jquery.dataTables.min.css"/>
<script>
$(document).ready(function(){
    var table = $("#authTable").DataTable({
        paging:true, searching:true, info:true, pageLength:50,
        lengthMenu: [ [10,25,50,100,-1],[10,25,50,100,"All"] ],
        dom:'frtip'
    });

    let btns = `
      <div style="margin-bottom:8px;">
        <button id="filterNoMFA" style="background:#ffcccc; border:1px solid #cc0000; padding:6px 12px; margin-right:5px; cursor:pointer;">❌ No MFA</button>
        <button id="filterSMS" style="background:#fff4c2; border:1px solid #e6b800; padding:6px 12px; margin-right:5px; cursor:pointer;">⚠️ SMS-Only</button>
        <button id="filterStrong" style="background:#d4f8d4; border:1px solid #2e8b57; padding:6px 12px; margin-right:5px; cursor:pointer;">✅ Strong MFA</button>
        <button id="filterPasswordless" style="background:#cce5ff; border:1px solid #3399ff; padding:6px 12px; margin-right:5px; cursor:pointer;">🗝️ Passwordless Ready</button>
        <button id="filterPhishResistant" style="background:#d1c4e9; border:1px solid #5e35b1; padding:6px 12px; margin-right:5px; cursor:pointer;">🛡️ Phish Resistant</button>
        <button id="clearFilter" style="background:#e6e6e6; border:1px solid #888; padding:6px 12px; cursor:pointer;">Reset</button>
      </div>
    `;
    $("#mfa-buttons-container").html(btns);

    const colIndexMFA=10, colIndexWindowsHello=7, colIndexFIDO2=6, colIndexAuthPwdLess=9;

    $("#filterNoMFA").on("click", function(){ table.column(colIndexMFA).search("No MFA").draw(); });
    $("#filterSMS").on("click", function(){ table.column(colIndexMFA).search("SMS-only").draw(); });
    $("#filterStrong").on("click", function(){ table.column(colIndexMFA).search("Strong").draw(); });

    // Custom search for Passwordless Ready
    $("#filterPasswordless").on("click", function(){
        $.fn.dataTable.ext.search = [];
        $.fn.dataTable.ext.search.push(
            function(settings, data, dataIndex){
                var winHello = parseInt(data[colIndexWindowsHello].match(/\((\d+)\)/)[1]) || 0;
                var fido2 = parseInt(data[colIndexFIDO2].match(/\((\d+)\)/)[1]) || 0;
                var authPwdLess = parseInt(data[colIndexAuthPwdLess].match(/\((\d+)\)/)[1]) || 0;
                return (winHello + fido2 + authPwdLess) > 0;
            }
        );
        table.draw();
    });

    // Custom search for Phish Resistant
    $("#filterPhishResistant").on("click", function(){
        $.fn.dataTable.ext.search = [];
        $.fn.dataTable.ext.search.push(
            function(settings, data, dataIndex){
                var winHello = parseInt(data[colIndexWindowsHello].match(/\((\d+)\)/)[1]) || 0;
                var fido2 = parseInt(data[colIndexFIDO2].match(/\((\d+)\)/)[1]) || 0;
                return (winHello + fido2) > 0;
            }
        );
        table.draw();
    });

    $("#clearFilter").on("click", function(){
        $.fn.dataTable.ext.search = [];
        table.search("").columns().search("").draw();
    });
});
</script>
'@

# Combine header, body, footer and write to the HTML file
($HtmlHeader + $HtmlBody + $HtmlFooter) | Out-File $HtmlFile -Encoding UTF8
Write-Host "HTML Report saved: $HtmlFile" -ForegroundColor Green
Write-Host "`n✅ Completed!" -ForegroundColor Cyan