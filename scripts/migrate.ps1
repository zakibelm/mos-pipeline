# MOS v5.0 — Database Migration Script (Windows / PowerShell)

$ErrorActionPreference = "Stop"

if (Test-Path ".env") {
    Get-Content ".env" | ForEach-Object {
        if ($_ -match "^([^#][^=]+)=(.+)$") {
            [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim())
        }
    }
}

if (-not $env:SUPABASE_URL -or -not $env:SUPABASE_SERVICE_KEY) {
    Write-Error "ERROR: SUPABASE_URL and SUPABASE_SERVICE_KEY must be set in .env"
    exit 1
}

$ProjectId = $env:SUPABASE_URL -replace "https://", "" -replace ".supabase.co", ""
$DbUrl = "postgresql://postgres:$($env:SUPABASE_SERVICE_KEY)@db.$ProjectId.supabase.co:5432/postgres"

Write-Host "Starting MOS migrations... Project: $ProjectId" -ForegroundColor Cyan

$Migrations = @(
    "migrations/000_extensions.sql",
    "migrations/001_v4_1_sprint1_base.sql",
    "migrations/002_v4_1_sprint2_rag.sql",
    "migrations/003_v4_1_sprint3_comfyui.sql",
    "migrations/004_v4_1_sprint4_fal.sql",
    "migrations/005_v4_1_sprint5_blotato.sql",
    "migrations/006_v4_1_sprint6_learning_loop.sql"
)

foreach ($migration in $Migrations) {
    if (Test-Path $migration) {
        Write-Host "  Applying $migration..." -NoNewline
        & psql $DbUrl -f $migration -q
        Write-Host " OK" -ForegroundColor Green
    } else {
        Write-Error "  ERROR: $migration not found"; exit 1
    }
}

Write-Host "All migrations applied!" -ForegroundColor Green
