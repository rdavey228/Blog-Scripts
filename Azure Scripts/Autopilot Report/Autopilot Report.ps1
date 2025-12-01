# Requires PowerShell 7
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Import-Module Microsoft.Graph.DeviceManagement -ErrorAction Stop

Connect-MgGraph -Scopes "Device.Read.All","User.Read.All","DeviceManagementManagedDevices.Read.All"

# Helper to fetch all pages from Graph
function Invoke-MgGraphAllPages {
    param(
        [Parameter(Mandatory = $true)][string]$Uri
    )
    $results = @()
    $next = $Uri
    while ($next) {
        $resp = Invoke-MgGraphRequest -Uri $next -Method GET
        if ($null -ne $resp.value) { $results += $resp.value }
        if ($resp.'@odata.nextLink') {
            $next = $resp.'@odata.nextLink'
        } else {
            $next = $null
        }
    }
    return $results
}

Write-Host "Retrieving Autopilot devices (paged)..."
$apDevices = Invoke-MgGraphAllPages -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$top=999"

Write-Host "Retrieving Intune managed devices (paged)..."
$intuneDevices = Invoke-MgGraphAllPages -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$top=999"

# Build hash of Intune devices keyed by managedDeviceId
$intuneHash = @{}
foreach ($d in $intuneDevices) {
    if ($d.id) { $intuneHash[$d.id] = $d }
}

Write-Host "Retrieving Entra (Azure AD) devices (paged)..."
$entraDevices = Invoke-MgGraphAllPages -Uri "https://graph.microsoft.com/v1.0/devices?`$top=999"

# Build hash: lowercase deviceId -> displayName and deviceId -> object id
$entraDisplayHash = @{}
$entraObjectIdHash = @{}
foreach ($ed in $entraDevices) {
    if ($ed.deviceId) {
        $key = $ed.deviceId.ToLower()
        $entraDisplayHash[$key] = $ed.displayName
        if ($ed.id) { $entraObjectIdHash[$key] = $ed.id }
    }
}

Write-Host "Building dataset..."
$rows = foreach ($ap in $apDevices) {
    $match = $null
    $primaryUser = $null
    $entraName = ""
    $entraId = ""
    $entraObjId = ""

    # --- Matching logic: Intune first, then Autopilot ---
    if ($ap.managedDeviceId -and $intuneHash.ContainsKey($ap.managedDeviceId)) {
        $match = $intuneHash[$ap.managedDeviceId]

        if ($match.azureADDeviceId) {
            $entraId = $match.azureADDeviceId.ToString().ToLower()
        }

        try {
            $userReq = Invoke-MgGraphRequest -Uri ("https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/" + $match.id + "/users") -Method GET
            if ($userReq.value -and $userReq.value.Count -gt 0) {
                $primaryUser = $userReq.value[0]
            }
        } catch {}
    }

    if (-not $entraId -and $ap.azureActiveDirectoryDeviceId) {
        $entraId = $ap.azureActiveDirectoryDeviceId.ToString().ToLower()
    }

    if ($entraId -and $entraDisplayHash.ContainsKey($entraId)) {
        $entraName = $entraDisplayHash[$entraId]
    }
    if ($entraId -and $entraObjectIdHash.ContainsKey($entraId)) {
        $entraObjId = $entraObjectIdHash[$entraId]
    }

    [pscustomobject]@{
        IntuneEnrolled         = if ($match) { "Yes" } else { "No" }
        IntuneDeviceName       = if ($match) { $match.deviceName } else { "" }
        EntraDeviceName        = $entraName
        EntraDeviceId          = $entraId
        EntraObjectId          = $entraObjId
        SerialNumber           = $ap.serialNumber
        PrimaryUserUPN         = if ($primaryUser) { $primaryUser.userPrincipalName } else { "" }
        PrimaryUserDisplayName = if ($primaryUser) { $primaryUser.displayName } else { "" }
        GroupTag               = $ap.groupTag
        Model                  = $ap.model
        Manufacturer           = $ap.manufacturer
        AutopilotId            = $ap.id
        ManagedDeviceId        = $ap.managedDeviceId
    }
}

# Build HTML rows
$htmlRows = ""
$enc = [System.Net.WebUtility]
foreach ($r in $rows) {
    $enrolledClass = if ($r.IntuneEnrolled -eq "Yes") { "yes" } else { "no" }

    $e_enrolled    = $enc::HtmlEncode([string]$r.IntuneEnrolled)
    $e_intune      = $enc::HtmlEncode([string]$r.IntuneDeviceName)
    $e_entra       = $enc::HtmlEncode([string]$r.EntraDeviceName)
    $e_entraIdAttr = $enc::HtmlEncode([string]$r.EntraDeviceId)
    $e_entraObjId  = $enc::HtmlEncode([string]$r.EntraObjectId)
    $e_serial      = $enc::HtmlEncode([string]$r.SerialNumber)
    $e_upn         = $enc::HtmlEncode([string]$r.PrimaryUserUPN)
    $e_display     = $enc::HtmlEncode([string]$r.PrimaryUserDisplayName)
    $e_group       = $enc::HtmlEncode([string]$r.GroupTag)
    $e_model       = $enc::HtmlEncode([string]$r.Model)
    $e_manuf       = $enc::HtmlEncode([string]$r.Manufacturer)
    $e_apId        = $enc::HtmlEncode([string]$r.AutopilotId)
    $e_mdId        = $enc::HtmlEncode([string]$r.ManagedDeviceId)

    # --- ONLY CHANGE: Add 🔗 emoji links (plain text remains visible) ---
    $intuneLink = ""
    if ($r.ManagedDeviceId) {
        $intuneLink = " <a href='https://intune.microsoft.com/#view/Microsoft_Intune_Devices/DeviceSettingsMenuBlade/~/overview/mdmDeviceId/$e_mdId' target='_blank' title='Open in Intune'>🔗</a>"
    }

    $entraLink = ""
    if ($r.EntraObjectId) {
        $entraLink = " <a href='https://entra.microsoft.com/#view/Microsoft_AAD_Devices/DeviceDetailsMenuBlade/~/overview/objectId/$e_entraObjId' target='_blank' title='Open in Entra'>🔗</a>"
    }

    $htmlRows += @"
<tr>
  <td><span class='pill $enrolledClass'>$e_enrolled</span></td>

  <td>$e_intune$intuneLink</td>

  <td data-entraid='$e_entraIdAttr'>$e_entra$entraLink</td>

  <td>$e_entraIdAttr</td>
  <td>$e_entraObjId</td>
  <td>$e_serial</td>
  <td>$e_upn</td>
  <td>$e_display</td>
  <td>$e_group</td>
  <td>$e_model</td>
  <td>$e_manuf</td>
  <td>$e_apId</td>
  <td>$e_mdId</td>
</tr>
"@
}

$htmlPath = "C:\Temp\Autopilot-Intune-Report.html"

# --- Final HTML with dropdown column filter, select all/deselect all, drag-reorder, localStorage persistence, and horizontal scroll ---
$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset='utf-8'>
<title>Autopilot → Intune Report</title>
<style>
body { margin: 0; background: #071026; color: #e6eef6; font-family: Inter, system-ui, Segoe UI, sans-serif; white-space: nowrap; }
.wrap { width: 100%; padding: 20px 32px; box-sizing: border-box; }
.card { background: rgba(255,255,255,0.03); padding: 18px; border-radius: 12px; box-shadow: 0 6px 18px rgba(0,0,0,0.4); width: 100%; box-sizing: border-box; }
h1 { margin: 0 0 16px 0; }
.sticky-top { position: sticky; top: 0; z-index: 10; padding-bottom: 10px; background: #071026; }

input, select, button { padding: 8px; border-radius: 8px; border: 1px solid rgba(255,255,255,0.08); background-color: #1e1e2f; color: #e6eef6; margin-right: 10px; }
button { border: none; background: #60a5fa; color: #04121f; cursor: pointer; }
button:hover { background: #93c5fd; }

.table-scroll { max-height: 72vh; overflow-y: auto; overflow-x: auto; white-space: nowrap; } /* horizontal scroll enabled */
.table-scroll::-webkit-scrollbar { width:10px; height:10px; }
.table-scroll::-webkit-scrollbar-track { background: #1e1e2f; }
.table-scroll::-webkit-scrollbar-thumb { background-color: #60a5fa; border-radius: 10px; border: 2px solid #1e1e2f; }
.table-scroll::-webkit-scrollbar-thumb:hover { background-color: #93c5fd; }
.table-scroll { scrollbar-width: thin; scrollbar-color: #60a5fa #1e1e2f; }

table { width: 100%; border-collapse: collapse; margin-top: 14px; font-size: 13px; }
th { position: sticky; top: 0; cursor: pointer; background: #1e1e2f; box-shadow: 0 2px 4px rgba(0,0,0,0.4); padding: 8px; text-align: left; font-size: 12px; user-select: none; z-index: 2; }
td { padding: 8px; border-top: 1px solid rgba(255,255,255,0.05); white-space: nowrap; }
tr:hover { background: rgba(255,255,255,0.04); }

.pill { padding: 6px 10px; border-radius: 999px; font-weight: 600; }
.yes { background: rgba(22,163,74,0.12); color: #16a34a; }
.no  { background: rgba(239,68,68,0.12); color: #ef4444; }

.search-bar { width: 320px; }
#fEntra { width: 260px; }
#fDevice { width: 220px; }
#fUPN { width: 220px; }
#fDisplay { width: 220px; }

.dropdown { position: relative; display: inline-block; margin-right: 10px; }
#groupDropdownBtn, #columnDropdownBtn { padding: 8px; border-radius: 8px; border: 1px solid rgba(255,255,255,0.08); background-color: #1e1e2f; color: #e6eef6; cursor: pointer; }
.dropdown-content { display: none; position: absolute; background-color: #1e1e2f; min-width: 200px; width: max-content; border: 1px solid rgba(255,255,255,0.08); border-radius: 8px; z-index: 100; max-height: 320px; overflow-y: auto; padding: 8px; }
.dropdown-content label { display: block; color: #e6eef6; margin-bottom: 6px; cursor: pointer; white-space: nowrap; }
.show { display: block; }

/* Column dropdown specific */
#columnDropdown .controls { display:flex; gap:8px; margin-bottom:8px; flex-wrap:wrap; }
#columnDropdown .controls button { padding:6px 8px; border-radius:6px; border:none; cursor:pointer; }
#selectAllCols { background:#10b981; color:#04121f; } /* green */
#deselectAllCols { background:#ef4444; color:white; }
.column-label { display:flex; align-items:center; gap:8px; padding:4px; border-radius:6px; }
.column-label[draggable='true'] { cursor: grab; }
.column-label:active { cursor: grabbing; }

/* subtle handle */
.column-handle { font-size: 10px; opacity:0.6; padding-right:6px; user-select:none; }
.column-handle::after { content:'⋮'; }

/* small helper for drop position mark */
.drop-indicator { height: 2px; background: #60a5fa; margin:4px 0; display:none; border-radius:2px; }

/* ensure long text wraps nicely inside dropdown */
#columnDropdown .col-text { overflow:hidden; text-overflow:ellipsis; max-width:320px; white-space:nowrap; }
</style>
</head>
<body>
<div class="wrap">

<div class="card sticky-top">
  <h1>Autopilot → Intune Interactive Report</h1>

  <input id="globalSearch" class="search-bar" placeholder="Search entire table…" oninput="globalSearch()">
  <hr style="border-color:rgba(255,255,255,0.05); margin:12px 0;">

  <div class="controls">
    <select id="fEnrolled" onchange="filterTable()">
      <option value="">Any</option>
      <option value="Yes">Yes</option>
      <option value="No">No</option>
    </select>

    <div class="dropdown">
      <button type="button" id="groupDropdownBtn">Group Tag ▼</button>
      <div id="groupDropdown" class="dropdown-content"></div>
    </div>

    <input id="fDevice" placeholder="Intune Device Name" oninput="filterTable()">
    <input id="fEntra" placeholder="Entra Device Name" oninput="filterTable()">
    <input id="fUPN" placeholder="Primary User UPN" oninput="filterTable()">
    <input id="fDisplay" placeholder="Display Name" oninput="filterTable()">

    <button onclick="filterTable()">Apply</button>
    <button onclick="clearAllFilters()">Clear All Filters</button>
    <button onclick="exportTable()">Export CSV</button>

    <!-- Column Filter dropdown (inline popout) -->
    <div class="dropdown" style="display:inline-block;">
      <button type="button" id="columnDropdownBtn">Column Filter ▼</button>
      <div id="columnDropdown" class="dropdown-content" aria-haspopup="true" aria-expanded="false"></div>
    </div>

  </div>
</div>

<div style="margin-top:10px; font-weight:bold;">
  Total Devices: <span id="deviceCount"></span>
</div>

<div class="card table-scroll">
  <table id="reportTable">
    <thead>
      <tr>
        <th onclick="sortTable(0)">Intune Enrolled</th>
        <th onclick="sortTable(1)">Intune Device Name</th>
        <th onclick="sortTable(2)">Entra Device Name</th>
        <th onclick="sortTable(3)">Entra Device ID</th>
        <th onclick="sortTable(4)">Entra Object ID</th>
        <th onclick="sortTable(5)">Serial Number</th>
        <th onclick="sortTable(6)">Primary User UPN</th>
        <th onclick="sortTable(7)">Primary User Display Name</th>
        <th onclick="sortTable(8)">Group Tag</th>
        <th onclick="sortTable(9)">Model</th>
        <th onclick="sortTable(10)">Manufacturer</th>
        <th onclick="sortTable(11)">AutopilotId</th>
        <th onclick="sortTable(12)">ManagedDeviceId</th>
      </tr>
    </thead>
    <tbody>
      $htmlRows
    </tbody>
  </table>
</div>

</div>

<script>
// --- JS functions (unchanged behavior where possible) ---
function globalSearch(){
    const val=document.getElementById("globalSearch").value.toLowerCase();
    const rows=document.querySelectorAll("#reportTable tbody tr");
    rows.forEach(r=>{
        r.style.display=r.innerText.toLowerCase().includes(val)?"":"none";
    });
    updateDeviceCount();
}

let sortDirection=true;
function sortTable(c){
    const t=document.getElementById("reportTable");
    let s=true;
    while(s){
        s=false;
        const rows=t.rows;
        for(let i=1;i<rows.length-1;i++){
            let x=rows[i].getElementsByTagName("TD")[c];
            let y=rows[i+1].getElementsByTagName("TD")[c];
            let xT=x?x.innerText.toLowerCase():"";
            let yT=y?y.innerText.toLowerCase():"";
            if(sortDirection?xT>yT:xT<yT){
                rows[i].parentNode.insertBefore(rows[i+1],rows[i]);
                s=true;
                break;
            }
        }
    }
    sortDirection=!sortDirection;
    updateDeviceCount();
}

function exportTable(){
    const t=document.getElementById("reportTable");
    const headers=[...t.querySelectorAll("thead th")].map(th=>'"'+th.innerText.replace(/"/g,'""')+'"').join(",");
    const rows=[...t.querySelectorAll("tbody tr")].filter(r=>r.style.display!=="none");
    const csvRows=rows.map(r=>[...r.children].map(c=>'"'+c.innerText.replace(/"/g,'""')+'"').join(","));
    const csv=[headers,...csvRows].join("\n");
    const blob=new Blob([csv],{type:"text/csv"});
    const url=URL.createObjectURL(blob);
    const a=document.createElement("a");
    a.href=url;
    a.download="Autopilot-Intune-Report.csv";
    a.click();
}

function filterTable(){
    const e=document.getElementById("fEnrolled").value.toLowerCase();
    const n=document.getElementById("fDevice").value.toLowerCase();
    const entra=document.getElementById("fEntra").value.toLowerCase();
    const u=document.getElementById("fUPN").value.toLowerCase();
    const d=document.getElementById("fDisplay").value.toLowerCase();
    const checkedBoxes=document.querySelectorAll('#groupDropdown input[type="checkbox"]:checked');
    const selectedGroups=Array.from(checkedBoxes).map(cb=>cb.value.toLowerCase());
    const rows=document.querySelectorAll("#reportTable tbody tr");
    rows.forEach(row=>{
        const cells=row.children;
        const enrolledMatch=!e||(cells[0]&&cells[0].innerText.toLowerCase().includes(e));
        const intuneNameMatch=!n||(cells[1]&&cells[1].innerText.toLowerCase().includes(n));
        const entraMatch=!entra||(cells[2]&&cells[2].innerText.toLowerCase().includes(entra));
        const upnMatch=!u||(cells[6]&&cells[6].innerText.toLowerCase().includes(u));
        const displayMatch=!d||(cells[7]&&cells[7].innerText.toLowerCase().includes(d));
        const groupText=(cells[8]&&cells[8].innerText.toLowerCase())||"";
        const groupMatch=(selectedGroups.length===0)||selectedGroups.includes(groupText);
        row.style.display=enrolledMatch&&intuneNameMatch&&entraMatch&&upnMatch&&displayMatch&&groupMatch?"":"none";
    });
    updateDeviceCount();
}

function clearAllFilters(){
    document.getElementById("globalSearch").value="";
    document.getElementById("fDevice").value="";
    document.getElementById("fEntra").value="";
    document.getElementById("fUPN").value="";
    document.getElementById("fDisplay").value="";
    document.getElementById("fEnrolled").value="";
    document.querySelectorAll('#groupDropdown input[type="checkbox"]').forEach(cb=>cb.checked=false);
    filterTable();
}

function updateDeviceCount(){
    const rows=document.querySelectorAll("#reportTable tbody tr");
    document.getElementById("deviceCount").innerText=Array.from(rows).filter(r=>r.style.display!=="none").length;
}

function populateGroupTags(){
    const rows=document.querySelectorAll("#reportTable tbody tr");
    const groupSet=new Set();
    rows.forEach(row=>{
        const val=row.children[8]?row.children[8].innerText.trim():"";
        groupSet.add(val===""?"__NONE__":val);
    });
    const groupDropdown=document.getElementById("groupDropdown");
    groupDropdown.innerHTML="";
    Array.from(groupSet).sort().forEach(labelText=>{
        const label=document.createElement("label");
        const checkbox=document.createElement("input");
        checkbox.type="checkbox";
        checkbox.value=labelText==="__NONE__"?"":labelText;
        checkbox.onchange=filterTable;
        label.appendChild(checkbox);
        label.appendChild(document.createTextNode(labelText==="__NONE__"?"None":labelText));
        groupDropdown.appendChild(label);
    });
    const btn=document.getElementById("groupDropdownBtn");
    btn.onclick=function(e){e.stopPropagation();groupDropdown.classList.toggle("show");};
    window.addEventListener('click',function(){groupDropdown.classList.remove('show')});
}

// ----- Column Dropdown: populate, toggle, select/deselect, drag reorder, save/load -----

const COL_ORDER_KEY = 'ap_report_col_order_v1';
const COL_VIS_KEY = 'ap_report_col_vis_v1';

function populateColumnDropdown() {
    const dropdown = document.getElementById("columnDropdown");
    const table = document.getElementById("reportTable");
    const headers = table.querySelectorAll("thead th");

    // get saved order & visibility
    let savedOrder = null;
    let savedVis = null;
    try {
        savedOrder = JSON.parse(localStorage.getItem(COL_ORDER_KEY));
        savedVis = JSON.parse(localStorage.getItem(COL_VIS_KEY));
    } catch(e) { savedOrder = null; savedVis = null; }

    // Build list of current header texts (in current DOM order)
    const currentHeaders = Array.from(headers).map(h=>h.innerText);

    // If saved order exists and matches the same set of headers, apply it now
    if (savedOrder && Array.isArray(savedOrder) && savedOrder.length === currentHeaders.length) {
        // attempt to reorder table to match savedOrder
        applyColumnOrder(savedOrder);
    }

    // After potential reordering, refresh header refs
    const freshHeaders = Array.from(document.querySelectorAll("#reportTable thead th"));

    dropdown.innerHTML = "";

    // top controls (Select All / Deselect All / Reset)
    const controls = document.createElement('div');
    controls.className = 'controls';
    const selAllBtn = document.createElement('button');
    selAllBtn.id = 'selectAllCols';
    selAllBtn.innerText = 'Select All';
    selAllBtn.onclick = function(e){ e.stopPropagation(); setAllColumns(true); };

    const deselAllBtn = document.createElement('button');
    deselAllBtn.id = 'deselectAllCols';
    deselAllBtn.innerText = 'Deselect All';
    deselAllBtn.onclick = function(e){ e.stopPropagation(); setAllColumns(false); };

    const resetBtn = document.createElement('button');
    resetBtn.id = 'resetCols';
    resetBtn.innerText = 'Reset';
    resetBtn.onclick = function(e){ e.stopPropagation(); localStorage.removeItem(COL_ORDER_KEY); localStorage.removeItem(COL_VIS_KEY); location.reload(); };

    controls.appendChild(selAllBtn);
    controls.appendChild(deselAllBtn);
    controls.appendChild(resetBtn);
    dropdown.appendChild(controls);

    // create labels for each header (draggable)
    freshHeaders.forEach((th, index) => {
        const wrapper = document.createElement('div');
        wrapper.className = 'column-label';
        wrapper.draggable = true;
        wrapper.dataset.index = index;

        // checkbox
        const cb = document.createElement("input");
        cb.type = "checkbox";
        cb.value = index;
        cb.checked = th.style.display !== "none";
        cb.onchange = function(e) {
            const idx = parseInt(this.value);
            toggleColumn(idx, this.checked);
            // save visibility after change
            saveColumnVisibility();
        };

        const handle = document.createElement('span');
        handle.className = 'column-handle';
        handle.innerText = ''; // visual handle (⋮) provided by CSS ::after

        const txt = document.createElement('span');
        txt.className = 'col-text';
        txt.innerText = th.innerText;

        wrapper.appendChild(handle);
        wrapper.appendChild(cb);
        wrapper.appendChild(txt);

        // drag handlers
        wrapper.addEventListener('dragstart', (ev) => {
            ev.dataTransfer.setData('text/plain', ev.currentTarget.dataset.index);
            ev.dataTransfer.effectAllowed = 'move';
            ev.currentTarget.style.opacity = '0.5';
        });
        wrapper.addEventListener('dragend', (ev) => {
            ev.currentTarget.style.opacity = '';
        });
        wrapper.addEventListener('dragover', (ev) => {
            ev.preventDefault();
            ev.dataTransfer.dropEffect = 'move';
        });
        wrapper.addEventListener('drop', (ev) => {
            ev.preventDefault();
            const src = parseInt(ev.dataTransfer.getData('text/plain'));
            const tgt = parseInt(ev.currentTarget.dataset.index);
            if (!isNaN(src) && !isNaN(tgt) && src !== tgt) {
                // reorder columns in table
                reorderColumns(src, tgt);
                // after reordering, rebuild dropdown to refresh indices & states
                populateColumnDropdown();
                // save order
                saveColumnOrder();
            }
        });

        dropdown.appendChild(wrapper);
    });

    // attach click handler to toggle dropdown
    const btn = document.getElementById("columnDropdownBtn");
    btn.onclick = function(e){
        e.stopPropagation();
        dropdown.classList.toggle("show");
    };

    // click outside closes dropdown
    window.addEventListener("click", function(){ document.getElementById("columnDropdown").classList.remove("show"); });

    // if saved visibility exists, apply it (match by header text)
    if (savedVis && Array.isArray(savedVis) && savedVis.length === freshHeaders.length) {
        // apply visibility in DOM order
        savedVis.forEach((vis, idx) => {
            toggleColumn(idx, !!vis);
        });
    }
}

// toggle one column show/hide based on current DOM index
function toggleColumn(colIndex, show) {
    const table = document.getElementById("reportTable");
    const ths = table.querySelectorAll("thead th");
    if (!ths[colIndex]) return;
    ths[colIndex].style.display = show ? "" : "none";
    table.querySelectorAll("tbody tr").forEach(row => {
        if (row.children[colIndex]) {
            row.children[colIndex].style.display = show ? "" : "none";
        }
    });
}

// set all columns to visible or hidden, then update checkboxes in dropdown
function setAllColumns(show) {
    const table = document.getElementById("reportTable");
    const ths = table.querySelectorAll("thead th");
    ths.forEach((th, idx) => {
        th.style.display = show ? "" : "none";
    });
    table.querySelectorAll("tbody tr").forEach(row=>{
        Array.from(row.children).forEach((cell, idx)=>{
            cell.style.display = show ? "" : "none";
        });
    });
    // refresh dropdown to update checkbox states
    populateColumnDropdown();
    saveColumnVisibility();
}

// reorder columns in the table (oldIndex -> newIndex)
function reorderColumns(oldIndex, newIndex) {
    const table = document.getElementById("reportTable");
    const rows = table.querySelectorAll("tr");
    rows.forEach(tr => {
        const cells = Array.from(tr.children);
        // guard in case of missing cells
        while (cells.length < Math.max(oldIndex, newIndex) + 1) {
            const filler = tr.tagName.toLowerCase() === 'thead' ? document.createElement('th') : document.createElement('td');
            filler.innerHTML = '';
            tr.appendChild(filler);
            cells.push(filler);
        }
        const moving = cells.splice(oldIndex, 1)[0];
        cells.splice(newIndex, 0, moving);
        // clear and re-append in new order
        tr.innerHTML = '';
        cells.forEach(c => tr.appendChild(c));
    });
    // after reordering, update any behaviors that rely on column index (none critical here)
    // save order
    saveColumnOrder();
}

// save column order (by header text) to localStorage
function saveColumnOrder() {
    try {
        const headers = Array.from(document.querySelectorAll("#reportTable thead th")).map(th => th.innerText);
        localStorage.setItem(COL_ORDER_KEY, JSON.stringify(headers));
    } catch(e) {}
    // also save visibility
    saveColumnVisibility();
}

// save visibility array (by header text order)
function saveColumnVisibility() {
    try {
        const ths = Array.from(document.querySelectorAll("#reportTable thead th"));
        const vis = ths.map(th => th.style.display !== "none");
        localStorage.setItem(COL_VIS_KEY, JSON.stringify(vis));
    } catch(e) {}
}

// apply a saved column order (array of header texts)
// this will reorder the table so headers are in that sequence
function applyColumnOrder(targetOrder) {
    const table = document.getElementById("reportTable");
    const currentHeaders = Array.from(table.querySelectorAll("thead th")).map(h => h.innerText);
    // build mapping current header text -> index
    const map = {};
    currentHeaders.forEach((t, i) => { map[t] = i; });

    // build new indices in terms of current indices
    const newIndices = targetOrder.map(t => (typeof map[t] !== 'undefined') ? map[t] : -1);

    // if any -1, abort (mismatch)
    if (newIndices.some(i => i < 0)) return;

    // reorder all rows using newIndices
    const rows = table.querySelectorAll("tr");
    rows.forEach(tr => {
        const cells = Array.from(tr.children);
        const newCells = newIndices.map(i => cells[i] || (tr.tagName.toLowerCase()==='thead' ? document.createElement('th') : document.createElement('td')));
        tr.innerHTML = '';
        newCells.forEach(c => tr.appendChild(c));
    });
}

// small helper to force rebuild dropdown & apply saved state on load
function initColumnControls() {
    populateColumnDropdown();
    updateDeviceCount();
}

// initialize on load
window.addEventListener('load', function(){
    populateGroupTags();
    initColumnControls();
    updateDeviceCount();
});

// ensure dropdowns close when clicking outside
window.addEventListener('click', function(){
    document.getElementById("groupDropdown").classList.remove("show");
    document.getElementById("columnDropdown").classList.remove("show");
});
</script>

</body>
</html>
"@

# Write file and open
$html | Out-File -FilePath $htmlPath -Encoding UTF8 -Force
Write-Host "Report written to: $htmlPath"
Start-Process $htmlPath
