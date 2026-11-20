# PowerShell deployment script for CloudFormation stack
# Usage: .\deploy-changeset.ps1 -Auto [-WithCicd] [-WithDatabases]

param(
    [switch]$Auto,
    [switch]$WithCicd,
    [switch]$WithDatabases
)

$ErrorActionPreference = "Stop"

# Configuration
$TEMPLATE_FILE = "cloudformation-template-validated.yml"
$STACK_NAME = "cgs-ai-analyst-agent-project"
$REGION = if ($env:AWS_REGION) { $env:AWS_REGION } else { "eu-north-1" }
$DESIRED_COUNT = if ($env:DESIRED_COUNT) { $env:DESIRED_COUNT } else { "1" }
$STREAMLIT_DESIRED_COUNT = if ($env:STREAMLIT_DESIRED_COUNT) { $env:STREAMLIT_DESIRED_COUNT } else { "1" }
$STREAMLIT_USERNAME = if ($env:STREAMLIT_USERNAME) { $env:STREAMLIT_USERNAME } else { "admin" }
$STREAMLIT_PASSWORD = if ($env:STREAMLIT_PASSWORD) { $env:STREAMLIT_PASSWORD } else { "" }

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "CloudFormation Deployment" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Stack Name:      $STACK_NAME"
Write-Host "Template:        $TEMPLATE_FILE"
Write-Host "Region:          $REGION"
Write-Host "Mode:            $(if ($Auto) { 'AUTO (deploy + push + start)' } else { 'REVIEW (change set only)' })"
Write-Host ""

# Check AWS CLI
Write-Host "Checking AWS CLI..." -ForegroundColor Yellow
$callerIdentity = aws sts get-caller-identity --region $REGION 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Error: AWS CLI not configured. Run 'aws configure' first." -ForegroundColor Red
    exit 1
}
Write-Host "✓ AWS CLI configured" -ForegroundColor Green

# Validate template
Write-Host ""
Write-Host "Validating template..." -ForegroundColor Yellow
aws cloudformation validate-template `
    --template-body "file://$TEMPLATE_FILE" `
    --region $REGION `
    | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Host "✓ Template valid" -ForegroundColor Green
} else {
    Write-Host "❌ Template validation failed" -ForegroundColor Red
    exit 1
}

# Check if stack exists
Write-Host ""
Write-Host "Checking stack status..." -ForegroundColor Yellow
$stackExists = $false
try {
    $stackStatus = aws cloudformation describe-stacks `
        --stack-name $STACK_NAME `
        --region $REGION `
        --query "Stacks[0].StackStatus" `
        --output text 2>$null
    
    if ($LASTEXITCODE -eq 0 -and $stackStatus -ne "DELETE_COMPLETE") {
        $stackExists = $true
        Write-Host "Stack exists with status: $stackStatus"
    }
} catch {
    Write-Host "Stack does not exist (will create new)"
}

# Determine change set type
$CHANGE_SET_TYPE = if ($stackExists) { "UPDATE" } else { "CREATE" }
Write-Host "Change Set Type: $CHANGE_SET_TYPE"

# Get account ID for bucket name
Write-Host ""
Write-Host "Detecting existing resources..." -ForegroundColor Yellow
$accountId = aws sts get-caller-identity --query Account --output text
$PRIMARY_DATA_BUCKET_NAME = "langchain-$accountId-eu-north-1"
$ATHENA_WORKGROUP_NAME = "project-text-to-sql"
$LIBRARY_GLUE_DATABASE_NAME = "project_library_db"
$CARS_GLUE_DATABASE_NAME = "project_cars_db"

# Check if bucket exists
$bucketExists = $false
try {
    aws s3api head-bucket --bucket $PRIMARY_DATA_BUCKET_NAME --region $REGION 2>$null
    if ($LASTEXITCODE -eq 0) {
        $bucketExists = $true
        Write-Host "✓ S3 bucket exists: $PRIMARY_DATA_BUCKET_NAME"
    }
} catch {}

$CREATE_PRIMARY_DATA_BUCKET = if ($bucketExists) { "false" } else { "true" }

# Check if Athena workgroup exists
$workgroupExists = $false
try {
    aws athena get-work-group --work-group $ATHENA_WORKGROUP_NAME --region $REGION 2>$null
    if ($LASTEXITCODE -eq 0) {
        $workgroupExists = $true
        Write-Host "✓ Athena workgroup exists: $ATHENA_WORKGROUP_NAME"
    }
} catch {}

$CREATE_ATHENA_WORKGROUP = if ($workgroupExists) { "false" } else { "true" }

# Check Glue databases
$libDbExists = $false
$carsDbExists = $false
try {
    aws glue get-database --name $LIBRARY_GLUE_DATABASE_NAME --region $REGION 2>$null
    if ($LASTEXITCODE -eq 0) { $libDbExists = $true }
} catch {}

try {
    aws glue get-database --name $CARS_GLUE_DATABASE_NAME --region $REGION 2>$null
    if ($LASTEXITCODE -eq 0) { $carsDbExists = $true }
} catch {}

$CREATE_LIBRARY_GLUE_DATABASE = if ($libDbExists) { "false" } else { "true" }
$CREATE_CARS_GLUE_DATABASE = if ($carsDbExists) { "false" } else { "true" }

# Set desired count to 0 for first deploy
$DEPLOY_DESIRED_COUNT = $DESIRED_COUNT
$DEPLOY_STREAMLIT_DESIRED_COUNT = $STREAMLIT_DESIRED_COUNT
if ($Auto -and $CHANGE_SET_TYPE -eq "CREATE") {
    $DEPLOY_DESIRED_COUNT = "0"
    $DEPLOY_STREAMLIT_DESIRED_COUNT = "0"
    Write-Host "Setting DesiredCount=0 for initial deploy"
}

# Create change set
$CHANGE_SET_NAME = "$STACK_NAME-changeset-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host ""
Write-Host "Creating change set: $CHANGE_SET_NAME" -ForegroundColor Yellow

$parameters = @"
[
  {"ParameterKey": "DesiredCount", "ParameterValue": "$DEPLOY_DESIRED_COUNT"},
  {"ParameterKey": "StreamlitDesiredCount", "ParameterValue": "$DEPLOY_STREAMLIT_DESIRED_COUNT"},
  {"ParameterKey": "StreamlitUsername", "ParameterValue": "$STREAMLIT_USERNAME"},
  {"ParameterKey": "StreamlitPassword", "ParameterValue": "$STREAMLIT_PASSWORD"},
  {"ParameterKey": "PrimaryDataBucketName", "ParameterValue": "$PRIMARY_DATA_BUCKET_NAME"},
  {"ParameterKey": "CreatePrimaryDataBucket", "ParameterValue": "$CREATE_PRIMARY_DATA_BUCKET"},
  {"ParameterKey": "AthenaWorkgroupName", "ParameterValue": "$ATHENA_WORKGROUP_NAME"},
  {"ParameterKey": "CreateAthenaWorkgroup", "ParameterValue": "$CREATE_ATHENA_WORKGROUP"},
  {"ParameterKey": "LibraryGlueDatabaseName", "ParameterValue": "$LIBRARY_GLUE_DATABASE_NAME"},
  {"ParameterKey": "CarsGlueDatabaseName", "ParameterValue": "$CARS_GLUE_DATABASE_NAME"},
  {"ParameterKey": "CreateLibraryGlueDatabase", "ParameterValue": "$CREATE_LIBRARY_GLUE_DATABASE"},
  {"ParameterKey": "CreateCarsGlueDatabase", "ParameterValue": "$CREATE_CARS_GLUE_DATABASE"},
  {"ParameterKey": "CreateAppLogGroup", "ParameterValue": "true"},
  {"ParameterKey": "CreateCrawlers", "ParameterValue": "$($Auto.ToString().ToLower())"}
]
"@

aws cloudformation create-change-set `
    --stack-name $STACK_NAME `
    --change-set-name $CHANGE_SET_NAME `
    --change-set-type $CHANGE_SET_TYPE `
    --template-body "file://$TEMPLATE_FILE" `
    --capabilities CAPABILITY_IAM `
    --region $REGION `
    --parameters $parameters `
    --tags Key=Environment,Value=production 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to create change set" -ForegroundColor Red
    exit 1
}

# Wait for change set
Write-Host "Waiting for change set to be created..." -ForegroundColor Yellow
aws cloudformation wait change-set-create-complete `
    --stack-name $STACK_NAME `
    --change-set-name $CHANGE_SET_NAME `
    --region $REGION

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Change set creation failed" -ForegroundColor Red
    
    # Check status
    $csStatus = aws cloudformation describe-change-set `
        --stack-name $STACK_NAME `
        --change-set-name $CHANGE_SET_NAME `
        --region $REGION `
        --query Status `
        --output text 2>$null
    
    $csReason = aws cloudformation describe-change-set `
        --stack-name $STACK_NAME `
        --change-set-name $CHANGE_SET_NAME `
        --region $REGION `
        --query StatusReason `
        --output text 2>$null
    
    Write-Host "Status: $csStatus"
    Write-Host "Reason: $csReason"
    
    # Clean up
    aws cloudformation delete-change-set `
        --stack-name $STACK_NAME `
        --change-set-name $CHANGE_SET_NAME `
        --region $REGION 2>$null
    
    if ($CHANGE_SET_TYPE -eq "CREATE") {
        aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION 2>$null
    }
    
    exit 1
}

# Show summary
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Change Set Summary:" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
aws cloudformation describe-change-set `
    --stack-name $STACK_NAME `
    --change-set-name $CHANGE_SET_NAME `
    --region $REGION `
    --query "Changes[*].[Type, ResourceChange.Action, ResourceChange.LogicalResourceId, ResourceChange.ResourceType]" `
    --output table

# Auto mode
if ($Auto) {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "AUTO MODE: Executing change set..." -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    
    aws cloudformation execute-change-set `
        --stack-name $STACK_NAME `
        --change-set-name $CHANGE_SET_NAME `
        --region $REGION
    
    Write-Host "Waiting for stack to complete (this may take 5-10 minutes)..." -ForegroundColor Yellow
    
    if ($CHANGE_SET_TYPE -eq "CREATE") {
        aws cloudformation wait stack-create-complete `
            --stack-name $STACK_NAME `
            --region $REGION
    } else {
        aws cloudformation wait stack-update-complete `
            --stack-name $STACK_NAME `
            --region $REGION
    }
    
    Write-Host "✓ Stack $CHANGE_SET_TYPE complete" -ForegroundColor Green
    
    # Seed data
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Seeding sample data into S3..." -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    
    # Upload cars data
    $carsFile = "POC\data\s3_cars_data_normalized.csv"
    if (Test-Path $carsFile) {
        Write-Host "Uploading cars data..."
        aws s3 cp $carsFile "s3://$PRIMARY_DATA_BUCKET_NAME/cars-data/" --region $REGION
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Cars data uploaded" -ForegroundColor Green
        }
    }
    
    # Upload library data
    $libraryFile = "POC\data\s3_library_data.json"
    if (Test-Path $libraryFile) {
        Write-Host "Uploading library data..."
        aws s3 cp $libraryFile "s3://$PRIMARY_DATA_BUCKET_NAME/library-data/" --region $REGION
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Library data uploaded" -ForegroundColor Green
        }
    }
    
    # CI/CD setup
    if ($WithCicd) {
        Write-Host ""
        Write-Host "==========================================" -ForegroundColor Cyan
        Write-Host "Setting up GitHub Actions OIDC..." -ForegroundColor Cyan
        Write-Host "==========================================" -ForegroundColor Cyan
        
        # Get GitHub remote
        $gitRemote = git remote get-url origin 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitRemote)) {
            Write-Host "❌ No git origin remote found. Set it first:" -ForegroundColor Red
            Write-Host "   git remote add origin https://github.com/OWNER/REPO.git"
            Write-Host "   git push -u origin main"
            exit 1
        }
        
        # Parse GitHub org/repo
        $gitRemote = $gitRemote.TrimEnd('/').TrimEnd('.git')
        $slug = ""
        if ($gitRemote -match "github\.com[/:](.+)/(.+)$") {
            $githubOrg = $matches[1]
            $githubRepo = $matches[2]
            Write-Host "GitHub repo: $githubOrg/$githubRepo"
        } else {
            Write-Host "❌ Could not parse GitHub repo from: $gitRemote" -ForegroundColor Red
            exit 1
        }
        
        # Deploy OIDC stack
        $OIDC_STACK = "github-actions-oidc"
        Write-Host "Deploying OIDC stack..."
        
        aws cloudformation deploy `
            --template-file cloudformation-github-oidc.yml `
            --stack-name $OIDC_STACK `
            --capabilities CAPABILITY_NAMED_IAM `
            --region $REGION `
            --no-fail-on-empty-changeset `
            --parameter-overrides "GitHubOrg=$githubOrg" "GitHubRepo=$githubRepo" 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            # Get role ARN
            $roleArn = aws cloudformation describe-stacks `
                --stack-name $OIDC_STACK `
                --region $REGION `
                --query "Stacks[0].Outputs[?OutputKey=='DeployRoleArn'].OutputValue" `
                --output text
            
            Write-Host "✓ OIDC role created: $roleArn" -ForegroundColor Green
            
            # Set GitHub secret if gh CLI is available
            $ghAvailable = Get-Command gh -ErrorAction SilentlyContinue
            if ($ghAvailable) {
                gh secret set AWS_DEPLOY_ROLE_ARN --repo "$githubOrg/$githubRepo" --body $roleArn 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "✓ GitHub secret set" -ForegroundColor Green
                }
            } else {
                Write-Host "ℹ️  Set GitHub secret manually:" -ForegroundColor Yellow
                Write-Host "   gh secret set AWS_DEPLOY_ROLE_ARN --repo `"$githubOrg/$githubRepo`" --body `"$roleArn`""
            }
            
            Write-Host ""
            Write-Host "==========================================" -ForegroundColor Cyan
            Write-Host "👉 NEXT STEP:" -ForegroundColor Cyan
            Write-Host "==========================================" -ForegroundColor Cyan
            Write-Host "Push to GitHub to trigger the build:"
            Write-Host ""
            Write-Host "   git push origin main"
            Write-Host ""
            Write-Host "Watch progress at: https://github.com/$githubOrg/$githubRepo/actions"
        }
    }
    
    # Run crawlers
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Running Glue Crawlers..." -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    
    $crawlers = @("project-library-crawler", "project-cars-crawler")
    foreach ($crawler in $crawlers) {
        Write-Host "Starting crawler: $crawler"
        aws glue start-crawler --name $crawler --region $REGION 2>$null
    }
    
    Write-Host "Waiting for crawlers to complete..."
    Start-Sleep -Seconds 60
    
    # Get outputs
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "✅ DEPLOYMENT COMPLETE" -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Cyan
    
    $albUrl = aws cloudformation describe-stacks `
        --stack-name $STACK_NAME `
        --region $REGION `
        --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerUrl'].OutputValue" `
        --output text 2>$null
    
    $streamlitUrl = aws cloudformation describe-stacks `
        --stack-name $STACK_NAME `
        --region $REGION `
        --query "Stacks[0].Outputs[?OutputKey=='StreamlitUrl'].OutputValue" `
        --output text 2>$null
    
    if ($albUrl -and $albUrl -ne "None") {
        Write-Host "🌐 API URL:     $albUrl" -ForegroundColor Green
        Write-Host "❤️  Health:      $albUrl/health"
        Write-Host "💬 Query:       curl -X POST $albUrl/query -H 'Content-Type: application/json' -d '{\"question\":\"How many books?\"}'"
    }
    
    if ($streamlitUrl -and $streamlitUrl -ne "None") {
        Write-Host "🖥️  Streamlit:   $streamlitUrl" -ForegroundColor Green
        Write-Host "🔑 Password:    aws secretsmanager get-secret-value --secret-id cgs-ai-analyst-agent/streamlit-credentials --region $REGION --query SecretString --output text"
    }
} else {
    # Review mode
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Next Steps:" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Run with -Auto to deploy:"
    Write-Host "    .\deploy-changeset.ps1 -Auto"
    Write-Host ""
    Write-Host "  Or with CI/CD:"
    Write-Host "    .\deploy-changeset.ps1 -Auto -WithCicd"
    Write-Host ""
}
