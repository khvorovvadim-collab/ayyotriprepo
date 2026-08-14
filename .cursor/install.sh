#!/usr/bin/env bash
# Idempotent Cloud Agent bootstrap for this PowerShell automation repo.
# Installs PowerShell (pwsh) and the PSScriptAnalyzer linter used to develop
# PowerBI_ALERT_Mattermost.ps1. Safe to run repeatedly.
set -euo pipefail

# 1. PowerShell (stable system toolchain) via Microsoft's apt repository.
if ! command -v pwsh >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . /etc/os-release
  tmp_deb="$(mktemp --suffix=.deb)"
  curl -fsSL "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -o "$tmp_deb"
  sudo dpkg -i "$tmp_deb"
  rm -f "$tmp_deb"
  sudo apt-get update
  sudo apt-get install -y powershell
fi

pwsh --version

# 2. PSScriptAnalyzer (lint tooling), installed only when missing.
pwsh -NoProfile -Command '
  $ErrorActionPreference = "Stop"
  Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
  if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber
  }
  $v = (Get-Module -ListAvailable -Name PSScriptAnalyzer | Select-Object -First 1).Version
  Write-Host "PSScriptAnalyzer $v ready"
'
