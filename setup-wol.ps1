[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [Alias('User')]
  [ValidateNotNullOrEmpty()]
  [string]$Username,

  [Parameter(Mandatory = $true)]
  [Alias('Pass')]
  [ValidateNotNullOrEmpty()]
  [string]$Password
)

$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
  )
}

function Grant-RemoteShutdownRight {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Sid
  )

  $tempRoot = Join-Path (
    [IO.Path]::GetTempPath()
  ) ("remote-shutdown-setup-{0}" -f [guid]::NewGuid().ToString('N'))
  $configPath = Join-Path $tempRoot 'user-rights.inf'
  $databasePath = Join-Path $tempRoot 'user-rights.sdb'
  $rightName = 'SeRemoteShutdownPrivilege'
  $sidEntry = "*$Sid"

  New-Item -ItemType Directory -Path $tempRoot | Out-Null

  try {
    & secedit.exe /export /cfg $configPath /areas USER_RIGHTS | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to export local security policy (exit code $LASTEXITCODE)."
    }

    [string[]]$content = Get-Content -LiteralPath $configPath
    $rightIndex = -1
    $sectionIndex = -1

    for ($index = 0; $index -lt $content.Count; $index++) {
      if ($content[$index] -match '^\s*\[Privilege Rights\]\s*$') {
        $sectionIndex = $index
      }

      if ($content[$index] -match "^\s*$rightName\s*=") {
        $rightIndex = $index
        break
      }
    }

    if ($rightIndex -ge 0) {
      $parts = $content[$rightIndex] -split '=', 2
      $assignments = @(
        $parts[1].Split(',') |
          ForEach-Object { $_.Trim() } |
          Where-Object { $_ }
      )

      if ($assignments -notcontains $sidEntry) {
        $assignments += $sidEntry
        $content[$rightIndex] = "$rightName = $($assignments -join ',')"
      }
    } else {
      if ($sectionIndex -lt 0) {
        throw 'Privilege Rights section was not found in the security policy.'
      }

      $updatedContent = New-Object System.Collections.Generic.List[string]
      for ($index = 0; $index -lt $content.Count; $index++) {
        $updatedContent.Add($content[$index])
        if ($index -eq $sectionIndex) {
          $updatedContent.Add("$rightName = $sidEntry")
        }
      }
      $content = $updatedContent.ToArray()
    }

    Set-Content -LiteralPath $configPath -Value $content -Encoding Unicode
    & secedit.exe /configure /db $databasePath /cfg $configPath /areas USER_RIGHTS |
      Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to apply local security policy (exit code $LASTEXITCODE)."
    }
  } finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTemp.StartsWith($systemTemp)) {
      Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Enable-LocalSubnetFirewallRule {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$DisplayName,

    [Parameter(Mandatory = $true)]
    [int]$Port
  )

  $rule = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
  if (-not $rule) {
    $rule = New-NetFirewallRule `
      -Name $Name `
      -DisplayName $DisplayName `
      -Direction Inbound `
      -Action Allow `
      -Protocol TCP `
      -LocalPort $Port `
      -RemoteAddress LocalSubnet `
      -Profile Private
  } else {
    $rule | Set-NetFirewallRule -Enabled True -Action Allow -Profile Private
    $rule | Get-NetFirewallAddressFilter |
      Set-NetFirewallAddressFilter -RemoteAddress LocalSubnet
  }
}

if (-not (Test-IsAdministrator)) {
  if (-not $PSCommandPath) {
    throw 'Save this script to a file before running it.'
  }

  $escapedScriptPath = $PSCommandPath.Replace("'", "''")
  $escapedUsername = $Username.Replace("'", "''")
  $escapedPassword = $Password.Replace("'", "''")
  $elevatedCommand =
    "& '$escapedScriptPath' -Username '$escapedUsername' -Password '$escapedPassword'"
  $encodedCommand = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($elevatedCommand)
  )
  $arguments = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-EncodedCommand',
    $encodedCommand
  )
  Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
  exit
}

Write-Host "Configuring remote shutdown on $env:COMPUTERNAME..." -ForegroundColor Cyan

$securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
$localUser = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue

if ($localUser) {
  Set-LocalUser `
    -Name $Username `
    -Password $securePassword `
    -PasswordNeverExpires $true `
    -Description 'Remote shutdown panel administrator'
  Enable-LocalUser -Name $Username
  Write-Host "Updated local user: $Username"
} else {
  $localUser = New-LocalUser `
    -Name $Username `
    -Password $securePassword `
    -PasswordNeverExpires `
    -AccountNeverExpires `
    -Description 'Remote shutdown panel administrator'
  Write-Host "Created local user: $Username"
}

$localUser = Get-LocalUser -Name $Username
$administratorsGroup = Get-LocalGroup -SID 'S-1-5-32-544'
$administratorMembers = @(
  Get-LocalGroupMember -Group $administratorsGroup -ErrorAction SilentlyContinue
)

if ($administratorMembers.SID.Value -notcontains $localUser.SID.Value) {
  Add-LocalGroupMember -Group $administratorsGroup -Member $localUser
  Write-Host "Added $Username to $($administratorsGroup.Name)."
} else {
  Write-Host "$Username is already an administrator."
}

Set-ItemProperty `
  -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
  -Name LocalAccountTokenFilterPolicy `
  -Type DWord `
  -Value 1

Set-Service -Name LanmanServer -StartupType Automatic
Start-Service -Name LanmanServer
Set-Service -Name RemoteRegistry -StartupType Automatic
Start-Service -Name RemoteRegistry

Enable-LocalSubnetFirewallRule `
  -Name 'STT-RemoteShutdown-SMB' `
  -DisplayName 'STT Remote Shutdown - SMB' `
  -Port 445
Enable-LocalSubnetFirewallRule `
  -Name 'STT-RemoteShutdown-RPC' `
  -DisplayName 'STT Remote Shutdown - RPC Endpoint Mapper' `
  -Port 135

$builtInRuleNames = @(
  'RemoteShutdown-In-TCP',
  'RemoteShutdown-RPCSS-In-TCP'
)
foreach ($ruleName in $builtInRuleNames) {
  $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
  if ($rule) {
    $rule | Set-NetFirewallRule -Enabled True -Profile Private
    $rule | Get-NetFirewallAddressFilter |
      Set-NetFirewallAddressFilter -RemoteAddress LocalSubnet
  }
}

Grant-RemoteShutdownRight -Sid $localUser.SID.Value

Write-Host ''
Write-Host 'Remote shutdown setup completed.' -ForegroundColor Green
Write-Host "Computer : $env:COMPUTERNAME"
Write-Host "Username : $Username"
Write-Host 'The currently logged-in Windows user was not changed.'
Write-Host 'A restart is recommended before the first remote shutdown test.'
