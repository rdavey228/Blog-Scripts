<#
.SYNOPSIS
    This script provides an interactive workflow to:
        1. Select one or more Azure subscriptions
        2. Select one or more resource groups from those subscriptions
        3. Select one or more Network Security Groups (NSGs)
        4. Select one or more ARM templates
        5. Select parameter files for each chosen template
        6. Deploy each template/parameter combination to each selected NSG

    The script supports multi-select for all stages and loops over all combinations
    to deploy consistently across multiple environments.

    Before execution, the script verifies if the user is logged into Azure.
    If the user is not logged in, it prompts for 'az login'.
#>

# -----------------------------
# 🔐 Azure Login Check
# -----------------------------
Write-Host "Checking Azure login status..." -ForegroundColor Cyan

$azAccount = az account show -o none 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Host "You are not logged into Azure." -ForegroundColor Yellow
    Write-Host "Opening Azure login..." -ForegroundColor Cyan
    az login | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Login failed. Exiting." -ForegroundColor Red
        exit
    }

    Write-Host "Login successful!" -ForegroundColor Green
} else {
    Write-Host "Already logged in to Azure." -ForegroundColor Green
}

# -----------------------------
# Helper: Multi-select parser
# -----------------------------
function Get-MultiSelectIndexes {
    param(
        [int]$count,
        [string]$prompt
    )

    $input = Read-Host $prompt
    $indexes = $input -split "," |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match "^\d+$" -and [int]$_ -ge 0 -and [int]$_ -lt $count } |
        ForEach-Object { [int]$_ }

    if ($indexes.Count -eq 0) {
        Write-Host "No valid selections. Exiting." -ForegroundColor Red
        exit
    }

    return $indexes
}

# -----------------------------
# 1️⃣ Multi-select subscriptions
# -----------------------------
$subs = az account list --query "[].{name:name, id:id}" -o json | ConvertFrom-Json

Write-Host "Available subscriptions:"
for ($i = 0; $i -lt $subs.Count; $i++) {
    Write-Host "[$i] $($subs[$i].name)"
}

$subIndexes = Get-MultiSelectIndexes -count $subs.Count -prompt "Select subscriptions (comma-separated)"
$selectedSubs = $subIndexes | ForEach-Object { $subs[$_] }

Write-Host "`nSelected subscriptions:"
$selectedSubs | ForEach-Object { Write-Host "- $($_.name)" }

# -----------------------------
# 2️⃣ Multi-select resource groups
# -----------------------------
$allRGs = @()

foreach ($sub in $selectedSubs) {
    az account set --subscription $sub.id

    $rgs = az group list --query "[].{name:name, subscription:'$($sub.id)'}" -o json | ConvertFrom-Json
    $allRGs += $rgs
}

Write-Host "`nAvailable resource groups:"
for ($i = 0; $i -lt $allRGs.Count; $i++) {
    Write-Host "[$i] $($allRGs[$i].name) (Sub: $($allRGs[$i].subscription))"
}

$rgIndexes = Get-MultiSelectIndexes -count $allRGs.Count -prompt "Select resource groups (comma-separated)"
$selectedRGs = $rgIndexes | ForEach-Object { $allRGs[$_] }

Write-Host "`nSelected resource groups:"
$selectedRGs | ForEach-Object { Write-Host "- $($_.name) (Sub: $($_.subscription))" }

# -----------------------------
# 3️⃣ Multi-select NSGs across selected RGs
# -----------------------------
$allNSGs = @()

foreach ($rg in $selectedRGs) {
    az account set --subscription $rg.subscription

    $nsgs = az network nsg list --resource-group $rg.name `
        --query "[].{name:name, rg:'$($rg.name)', subscription:'$($rg.subscription)'}" -o json |
        ConvertFrom-Json

    $allNSGs += $nsgs
}

Write-Host "`nAvailable NSGs:"
for ($i = 0; $i -lt $allNSGs.Count; $i++) {
    Write-Host "[$i] $($allNSGs[$i].name) (RG: $($allNSGs[$i].rg), Sub: $($allNSGs[$i].subscription))"
}

$nsgIndexes = Get-MultiSelectIndexes -count $allNSGs.Count -prompt "Select NSGs (comma-separated)"
$selectedNSGs = $nsgIndexes | ForEach-Object { $allNSGs[$_] }

Write-Host "`nSelected NSGs:"
$selectedNSGs | ForEach-Object { Write-Host "- $($_.name) in RG $($_.rg) (Sub: $($_.subscription))" }

# -----------------------------
# 4️⃣ Multi-select templates
# -----------------------------
$templates = Get-ChildItem -Path "$PSScriptRoot/../templates" -Filter *.json

Write-Host "`nAvailable templates:"
for ($i = 0; $i -lt $templates.Count; $i++) {
    Write-Host "[$i] $($templates[$i].Name)"
}

$templateIndexes = Get-MultiSelectIndexes -count $templates.Count -prompt "Select templates (comma-separated)"
$selectedTemplates = $templateIndexes | ForEach-Object { $templates[$_] }

# -----------------------------
# 5️⃣ Multi-select parameters per template
# -----------------------------
$templateParamMap = @()

foreach ($template in $selectedTemplates) {
    $templateName = [System.IO.Path]::GetFileNameWithoutExtension($template.FullName)
    $parametersFolder = "$PSScriptRoot/../parameters/$templateName"

    if (-not (Test-Path $parametersFolder)) {
        Write-Host "`n❌ Parameters folder not found for template $templateName"
        continue
    }

    $params = Get-ChildItem -Path $parametersFolder -Filter *.json

    Write-Host "`nAvailable parameters for template ${templateName}:"
    for ($i = 0; $i -lt $params.Count; $i++) {
        Write-Host "[$i] $($params[$i].Name)"
    }

    $paramIndexes = Get-MultiSelectIndexes -count $params.Count -prompt "Select parameter files (comma-separated)"

    foreach ($index in $paramIndexes) {
        $templateParamMap += [PSCustomObject]@{
            Template     = $template.FullName
            TemplateName = $templateName
            ParamFile    = $params[$index].FullName
        }
    }
}

# -----------------------------
# 7️⃣ Deployment Loop (subs × RGs × NSGs × templates × params)
# -----------------------------
foreach ($nsg in $selectedNSGs) {

    az account set --subscription $nsg.subscription

    foreach ($item in $templateParamMap) {

        Write-Host "`nDeploying template $($item.TemplateName) to NSG $($nsg.name) in RG $($nsg.rg) (Sub: $($nsg.subscription))..."

        # ✅ FIXED: Correct parameter file syntax
        $deployment = az deployment group create `
            --resource-group $nsg.rg `
            --template-file $item.Template `
            --parameters $item.ParamFile `
            --parameters nsgName=$($nsg.name) `
            -o json | ConvertFrom-Json

        if ($deployment.properties.provisioningState -eq "Succeeded") {
            Write-Host "Deployment Successful ✅" -ForegroundColor Green
        } else {
            Write-Host "Deployment Failed ❌" -ForegroundColor Red
            if ($deployment.properties.error) {
                Write-Host ($deployment.properties.error | ConvertTo-Json -Depth 5)
            }
        }
    }
}
