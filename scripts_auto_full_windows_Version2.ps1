<#
.SYNOPSIS
  Script de automação para Windows (PowerShell) que:
  - valida pré-requisitos (git, node, npm, gh)
  - comita o diretório atual (se necessário)
  - cria/usa repositório GitHub (owner/repo)
  - cria branches do workflow e commita um marcador por branch
  - abre PRs no GitHub usando templates em pr_templates/ (se existirem)
  - opcional: cria buckets no Supabase via REST (pede SUPABASE_SERVICE_ROLE_KEY)
  - opcional: executa scripts/setup-db.ps1 (se existir)
  - não envia suas chaves a nenhum lugar; tudo roda localmente
.NOTES
  - Execute em PowerShell (não cmd), na pasta raiz do projeto.
  - Antes de rodar: gh auth login (autentique o gh CLI).
#>

[CmdletBinding()]
param()

function Write-ErrorAndExit($msg) {
  Write-Host ""
  Write-Host "ERRO: $msg" -ForegroundColor Red
  Exit 1
}

function Check-Command($cmd, $friendly) {
  try {
    & $cmd --version > $null 2>&1
    return $true
  } catch {
    Write-Host "Aviso: $friendly não encontrado ou não está no PATH." -ForegroundColor Yellow
    return $false
  }
}

Write-Host "=== Telemed MVP - Automação (Windows PowerShell) ===" -ForegroundColor Cyan
Start-Sleep -Seconds 0.5

# 1) Pré-requisitos
$haveGit = Check-Command "git" "git"
$haveNode = Check-Command "node" "Node.js"
$haveNpm  = Check-Command "npm" "npm"
$haveGh   = Check-Command "gh" "GitHub CLI (gh)"

if (-not $haveGit) { Write-ErrorAndExit "Instale git (https://git-scm.com/) e adicione ao PATH antes de continuar." }
if (-not $haveNode) { Write-ErrorAndExit "Instale Node.js (https://nodejs.org/) antes de continuar." }
if (-not $haveNpm)  { Write-ErrorAndExit "npm não encontrado (instale Node.js LTS)." }
if (-not $haveGh)   { 
  Write-Host ""
  Write-Host "GitHub CLI (gh) não está disponível. Deseja continuar sem criar PRs automaticamente? (y/N)" -ForegroundColor Yellow
  $ans = Read-Host
  if ($ans -ne 'y' -and $ans -ne 'Y') {
    Write-ErrorAndExit "Instale gh CLI e rode 'gh auth login' antes de reexecutar este script. Recomendo usar winget/choco ou o instalador MSI."
  } else {
    Write-Host "Continuando sem integração gh (PRs não serão criados)." -ForegroundColor Yellow
  }
}

# 2) Confirm working directory
$cwd = Get-Location
Write-Host "Pasta atual: $cwd"

# 3) Repo target (defaults)
$defaultOwner = "gabisenaa"
$defaultRepo  = "telemed-mvp"
$inputOwner = Read-Host "Owner do GitHub (enter para usar '$defaultOwner')"
if ([string]::IsNullOrWhiteSpace($inputOwner)) { $inputOwner = $defaultOwner }
$inputRepo = Read-Host "Nome do repositório (enter para usar '$defaultRepo')"
if ([string]::IsNullOrWhiteSpace($inputRepo)) { $inputRepo = $defaultRepo }
$fullRepo = "$inputOwner/$inputRepo"
Write-Host "Usando repositório: $fullRepo"

# 4) Inicializar git se necessário e commit inicial
if (-not (Test-Path ".git")) {
  Write-Host "Inicializando repositório git..."
  git init
}

# Stage all files but ensure .env is ignored (do not add secrets)
if (-not (git rev-parse --is-inside-work-tree 2>$null)) {
  Write-ErrorAndExit "Não parece um repo git. Saindo."
}

# Check for uncommitted changes
$porcelain = git status --porcelain
if ($porcelain) {
  Write-Host "Existem alterações não comitadas. Criando commit inicial automatizado..."
  git add -A
  git commit -m "chore: initial project files (auto-generated)"
} else {
  Write-Host "Nenhuma alteração para commitar."
}

# 5) Criar repo no GitHub (se gh disponível)
if ($haveGh) {
  try {
    gh repo view $fullRepo --json name >/dev/null 2>&1
    Write-Host "Repositório $fullRepo já existe no GitHub."
  } catch {
    Write-Host "Criando repositório $fullRepo no GitHub..."
    # Try to create with source=.
    gh repo create $fullRepo --public --source="." --remote=origin --confirm 2>&1 | Write-Host
  }
} else {
  Write-Host "gh CLI não disponível: pulei criação remota. Você pode criar o repositório manualmente no GitHub e adicionar origin."
}

# 6) Ensure remote origin and push main
try {
  git remote get-url origin > $null 2>&1
} catch {
  $remoteUrl = "git@github.com:$fullRepo.git"
  git remote add origin $remoteUrl 2>$null
}

# Ensure main branch exists
try {
  git rev-parse --verify main > $null 2>&1
  git checkout main
} catch {
  git checkout -b main
}

# Push main
try {
  git push -u origin main
} catch {
  Write-Host "Aviso: push falhou. Verifique permissões do remote. Continuando..."
}

# 7) Branches workflow + PRs
$branches = @(
  "feature/base-setup",
  "feature/db-schema",
  "feature/pages",
  "feature/components",
  "feature/uploads",
  "feature/pdf-email",
  "feature/audit-log",
  "feature/tests",
  "docs/readme-deploy"
)

foreach ($br in $branches) {
  Write-Host ""
  Write-Host "=== Processando branch $br ===" -ForegroundColor Cyan
  # Create branch (if exists try checkout)
  try {
    git checkout -b $br main 2>$null
  } catch {
    git checkout $br 2>$null
  }

  # Create a small marker file and commit
  $marker = ".branch-" + ($br -replace '/', '-') + ".marker"
  Set-Content -Path $marker -Value ("marker for branch $br - created on " + (Get-Date).ToString("u"))
  git add $marker
  git commit -m "chore: scaffold for $br" 2>$null

  # push
  try {
    git push -u origin $br
  } catch {
    Write-Host "Aviso: git push para $br falhou (verifique permissões)." -ForegroundColor Yellow
  }

  # Create PR if gh available
  if ($haveGh) {
    $bodyfile = "pr_templates/" + ($br -replace '/', '-') + ".md"
    $title = "feat: $br"
    try {
      if (Test-Path $bodyfile) {
        gh pr create --base main --head $br --title $title --body-file $bodyfile --fill 2>&1 | Write-Host
      } else {
        # Minimal PR body
        $prbody = @"
Automated PR for branch $br.

Checklist:
- [ ] Código compilando
- [ ] Rotas principais acessíveis
- [ ] Migrações aplicadas (se aplicável)
"@
        gh pr create --base main --head $br --title $title --body $prbody --fill 2>&1 | Write-Host
      }
    } catch {
      Write-Host "Aviso: falha ao criar PR para $br via gh CLI. Você pode criar manualmente no GitHub." -ForegroundColor Yellow
    }
  } else {
    Write-Host "gh CLI ausente — PR não criado para $br."
  }

  # checkout main again for next iteration
  git checkout main
}

# 8) Opcional: criar buckets via Supabase REST (pede info ao usuário)
Write-Host ""
$createBuckets = Read-Host "Deseja criar os buckets 'case-files' e 'reports' no Supabase agora? (y/N)"
if ($createBuckets -eq 'y' -or $createBuckets -eq 'Y') {
  $sbUrl = Read-Host "Informe SUPABASE_SERVICE_URL (ex: https://xyz.supabase.co)"
  $sbKey = Read-Host "Informe SUPABASE_SERVICE_ROLE_KEY (esta será usada somente localmente, não é enviada a terceiros)"
  if ([string]::IsNullOrWhiteSpace($sbUrl) -or [string]::IsNullOrWhiteSpace($sbKey)) {
    Write-Host "SUPABASE_SERVICE_URL ou SUPABASE_SERVICE_ROLE_KEY ausentes. Pulando criação de buckets."
  } else {
    $headers = @{
      "apikey" = $sbKey
      "Authorization" = "Bearer $sbKey"
      "Content-Type" = "application/json"
    }
    try {
      Write-Host "Criando bucket case-files..."
      Invoke-RestMethod -Uri ("$sbUrl/rest/v1/storage/buckets") -Method Post -Headers $headers -Body ('{"name":"case-files","public":false}') -ErrorAction Stop
      Write-Host "Criando bucket reports..."
      Invoke-RestMethod -Uri ("$sbUrl/rest/v1/storage/buckets") -Method Post -Headers $headers -Body ('{"name":"reports","public":false}') -ErrorAction Stop
      Write-Host "Buckets processados. Verifique no painel do Supabase."
    } catch {
      Write-Host "Aviso: criação de buckets via API retornou erro: $($_.Exception.Message)" -ForegroundColor Yellow
      Write-Host "Você pode criar manualmente via painel Supabase -> Storage."
    }
  }
} else {
  Write-Host "Pulando criação automática de buckets."
}

# 9) Opcional: executar scripts/setup-db.ps1 se existir
if (Test-Path ".\scripts\setup-db.ps1") {
  $runSetup = Read-Host "Deseja executar scripts\\setup-db.ps1 agora? (ex.: cria buckets) (y/N)"
  if ($runSetup -eq 'y' -or $runSetup -eq 'Y') {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    try {
      .\scripts\setup-db.ps1
      Write-Host "scripts\\setup-db.ps1 executado (verifique mensagens acima)."
    } catch {
      Write-Host "Falha ao executar scripts\\setup-db.ps1: $($_.Exception.Message)" -ForegroundColor Yellow
    }
  } else {
    Write-Host "Pulando scripts\\setup-db.ps1."
  }
} else {
  Write-Host "Não há scripts\\setup-db.ps1 no projeto. Pulei essa etapa."
}

# 10) Final steps
Write-Host ""
Write-Host "=== Automação finalizada ===" -ForegroundColor Green
Write-Host "Próximos passos recomendados:"
Write-Host "1) Verifique os Pull Requests em: https://github.com/$fullRepo/pulls"
Write-Host "2) No Supabase, aplique as migrations (migrations/*.sql) via SQL Editor se ainda não aplicou."
Write-Host "3) Defina variáveis de ambiente (no seu .env local e no Vercel) e rode 'npm run dev' para testes locais."
Write-Host ""
Write-Host "Se algo falhar, cole aqui a saída do PowerShell e eu te guio no próximo passo." -ForegroundColor Cyan