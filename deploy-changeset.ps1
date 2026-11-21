# PowerShell deployment script for CloudFormation stack
# Usage:
#   .\deploy-changeset.ps1              # Review mode: creates change set, shows summary
#   .\deploy-changeset.ps1 -Auto        # Full auto: deploy stack + seed data + start service
#   .\deploy-changeset.ps1 -Auto -WithCicd       # Also wire GitHub Actions OIDC
#   .\deploy-changeset.ps1 -Auto -WithDatabases  # Also deploy RDS Aurora + Redshift

param(
    [switch]$Auto,
    [switch]$WithCicd,
    [switch]$WithDatabases
)

$ErrorActionPreference = "Stop"

# ── Helper: run AWS check without throwing on stderr ──────────────────────
function Invoke-AwsCheck {
    param([string[]]$Arguments)
    $old = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $output = & aws @Arguments 2>$null
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $old
    return @{ Output = $output; Success = ($exit -eq 0) }
}

# ── Configuration ──────────────────────────────────────────────────────────
$TEMPLATE_FILE = "cloudformation-template-validated.yml"
$STACK_NAME    = "cgs-ai-analyst-agent-project"
$REGION        = if ($env:AWS_REGION) { $env:AWS_REGION } else { "eu-north-1" }
$DESIRED_COUNT = if ($env:DESIRED_COUNT) { $env:DESIRED_COUNT } else { "1" }
$STREAMLIT_DESIRED_COUNT = if ($env:STREAMLIT_DESIRED_COUNT) { $env:STREAMLIT_DESIRED_COUNT } else { "1" }
$STREAMLIT_USERNAME = if ($env:STREAMLIT_USERNAME) { $env:STREAMLIT_USERNAME } else { "admin" }
$STREAMLIT_PASSWORD = if ($env:STREAMLIT_PASSWORD) { $env:STREAMLIT_PASSWORD } else { "" }

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "CloudFormation Deployment" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Stack Name : $STACK_NAME"
Write-Host "Template   : $TEMPLATE_FILE"
Write-Host "Region     : $REGION"
$modeLabel = if ($Auto) { "AUTO (deploy + seed + start)" } else { "REVIEW (change set only)" }
Write-Host "Mode       : $modeLabel"
Write-Host ""

# ── Check AWS CLI ──────────────────────────────────────────────────────────
Write-Host "Checking AWS CLI..." -ForegroundColor Yellow
$check = Invoke-AwsCheck @("sts", "get-caller-identity", "--region", $REGION)
if (-not $check.Success) {
    Write-Host "ERROR: AWS CLI not configured. Run 'aws configure' first." -ForegroundColor Red
    exit 1
}
Write-Host "OK: AWS CLI configured" -ForegroundColor Green

# ── Validate template ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "Validating template..." -ForegroundColor Yellow
$valCheck = Invoke-AwsCheck @("cloudformation", "validate-template", "--template-body", "file://$TEMPLATE_FILE", "--region", $REGION)
if (-not $valCheck.Success) {
    Write-Host "ERROR: Template validation failed" -ForegroundColor Red
    exit 1
}
Write-Host "OK: Template valid" -ForegroundColor Green

# ── Check if stack exists ──────────────────────────────────────────────────
Write-Host ""
Write-Host "Checking stack status..." -ForegroundColor Yellow
$stackCheck = Invoke-AwsCheck @("cloudformation", "describe-stacks", "--stack-name", $STACK_NAME, "--region", $REGION, "--query", "Stacks[0].StackStatus", "--output", "text")
$stackExists = $stackCheck.Success -and $stackCheck.Output -ne "DELETE_COMPLETE"
$stackStatus = if ($stackCheck.Success) { $stackCheck.Output } else { "NOT_FOUND" }

if ($stackExists) {
    Write-Host "Stack exists with status: $stackStatus"
} else {
    Write-Host "Stack does not exist (will create new)"
}

$CHANGE_SET_TYPE = if ($stackExists) { "UPDATE" } else { "CREATE" }
Write-Host "Change Set Type: $CHANGE_SET_TYPE"

# ── Detect existing resources ──────────────────────────────────────────────
Write-Host ""
Write-Host "Detecting existing resources..." -ForegroundColor Yellow
$accountIdCheck = Invoke-AwsCheck @("sts", "get-caller-identity", "--query", "Account", "--output", "text")
$accountId = $accountIdCheck.Output.Trim()
$PRIMARY_DATA_BUCKET_NAME   = "langchain-$accountId-eu-north-1"
$ATHENA_WORKGROUP_NAME      = "project-text-to-sql"
$LIBRARY_GLUE_DATABASE_NAME = "avag_vehicles_db"
$CARS_GLUE_DATABASE_NAME    = "avag_vehicles_db"

# S3 bucket
$bucketCheck = Invoke-AwsCheck @("s3api", "head-bucket", "--bucket", $PRIMARY_DATA_BUCKET_NAME, "--region", $REGION)
$CREATE_PRIMARY_DATA_BUCKET = if ($bucketCheck.Success) { "false" } else { "true" }
if ($bucketCheck.Success) { Write-Host "  Reusing S3 bucket: $PRIMARY_DATA_BUCKET_NAME" }

# Athena workgroup
$wgCheck = Invoke-AwsCheck @("athena", "get-work-group", "--work-group", $ATHENA_WORKGROUP_NAME, "--region", $REGION, "--query", "WorkGroup.State", "--output", "text")
$CREATE_ATHENA_WORKGROUP = if ($wgCheck.Success -and $wgCheck.Output.Trim() -eq "ENABLED") { "false" } else { "true" }
if ($wgCheck.Success -and $wgCheck.Output.Trim() -eq "ENABLED") { Write-Host "  Reusing Athena workgroup: $ATHENA_WORKGROUP_NAME" }

# Glue database
$glueCheck = Invoke-AwsCheck @("glue", "get-database", "--name", $LIBRARY_GLUE_DATABASE_NAME, "--region", $REGION)
$CREATE_LIBRARY_GLUE_DATABASE = if ($glueCheck.Success) { "false" } else { "true" }
if ($glueCheck.Success) { Write-Host "  Reusing Glue DB: $LIBRARY_GLUE_DATABASE_NAME" }

# Both DB names are identical — only create one
$CREATE_CARS_GLUE_DATABASE = "false"

# CloudWatch log group
$lgCheck = Invoke-AwsCheck @("logs", "describe-log-groups", "--log-group-name-prefix", "/ecs/data-architecture-ai", "--region", $REGION, "--query", "logGroups[?logGroupName=='/ecs/data-architecture-ai'].logGroupName", "--output", "text")
$CREATE_APP_LOG_GROUP = if ($lgCheck.Success -and $lgCheck.Output -match "data-architecture-ai") { "false" } else { "true" }
if ($lgCheck.Success -and $lgCheck.Output -match "data-architecture-ai") { Write-Host "  Reusing CloudWatch log group: /ecs/data-architecture-ai" }

# ── Desired count: 0 on first deploy until image is pushed ────────────────
$DEPLOY_DESIRED_COUNT = $DESIRED_COUNT
$DEPLOY_STREAMLIT_DESIRED_COUNT = $STREAMLIT_DESIRED_COUNT
if ($Auto -and $CHANGE_SET_TYPE -eq "CREATE") {
    $DEPLOY_DESIRED_COUNT = "0"
    $DEPLOY_STREAMLIT_DESIRED_COUNT = "0"
    Write-Host "  Setting DesiredCount=0 for initial deploy (image not pushed yet)"
}

# Crawlers skipped — Lambda creates them automatically on S3 upload
$CREATE_CRAWLERS_PARAM = if ($env:CREATE_CRAWLERS -eq "true") { "true" } else { "false" }

# ── Create change set ──────────────────────────────────────────────────────
$CHANGE_SET_NAME = "$STACK_NAME-changeset-$(Get-Date -Format 'yyyyMMddHHmmss')"

$parameters = @(
    "ParameterKey=DesiredCount,ParameterValue=$DEPLOY_DESIRED_COUNT",
    "ParameterKey=StreamlitDesiredCount,ParameterValue=$DEPLOY_STREAMLIT_DESIRED_COUNT",
    "ParameterKey=StreamlitUsername,ParameterValue=$STREAMLIT_USERNAME",
    "ParameterKey=StreamlitPassword,ParameterValue=$STREAMLIT_PASSWORD",
    "ParameterKey=PrimaryDataBucketName,ParameterValue=$PRIMARY_DATA_BUCKET_NAME",
    "ParameterKey=CreatePrimaryDataBucket,ParameterValue=$CREATE_PRIMARY_DATA_BUCKET",
    "ParameterKey=AthenaWorkgroupName,ParameterValue=$ATHENA_WORKGROUP_NAME",
    "ParameterKey=CreateAthenaWorkgroup,ParameterValue=$CREATE_ATHENA_WORKGROUP",
    "ParameterKey=LibraryGlueDatabaseName,ParameterValue=$LIBRARY_GLUE_DATABASE_NAME",
    "ParameterKey=CarsGlueDatabaseName,ParameterValue=$CARS_GLUE_DATABASE_NAME",
    "ParameterKey=CreateLibraryGlueDatabase,ParameterValue=$CREATE_LIBRARY_GLUE_DATABASE",
    "ParameterKey=CreateCarsGlueDatabase,ParameterValue=$CREATE_CARS_GLUE_DATABASE",
    "ParameterKey=CreateAppLogGroup,ParameterValue=$CREATE_APP_LOG_GROUP",
    "ParameterKey=CreateCrawlers,ParameterValue=$CREATE_CRAWLERS_PARAM"
)

Write-Host ""
Write-Host "Creating change set: $CHANGE_SET_NAME" -ForegroundColor Yellow

& aws cloudformation create-change-set `
    --stack-name $STACK_NAME `
    --change-set-name $CHANGE_SET_NAME `
    --change-set-type $CHANGE_SET_TYPE `
    --template-body "file://$TEMPLATE_FILE" `
    --capabilities CAPABILITY_IAM `
    --region $REGION `
    --parameters $parameters `
    --tags "Key=Environment,Value=production"

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to create change set" -ForegroundColor Red
    exit 1
}

# ── Wait for change set ────────────────────────────────────────────────────
Write-Host "Waiting for change set..." -ForegroundColor Yellow
$waitCheck = Invoke-AwsCheck @("cloudformation", "wait", "change-set-create-complete", "--stack-name", $STACK_NAME, "--change-set-name", $CHANGE_SET_NAME, "--region", $REGION)

if (-not $waitCheck.Success) {
    $csStatus = (Invoke-AwsCheck @("cloudformation", "describe-change-set", "--stack-name", $STACK_NAME, "--change-set-name", $CHANGE_SET_NAME, "--region", $REGION, "--query", "Status", "--output", "text")).Output
    $csReason = (Invoke-AwsCheck @("cloudformation", "describe-change-set", "--stack-name", $STACK_NAME, "--change-set-name", $CHANGE_SET_NAME, "--region", $REGION, "--query", "StatusReason", "--output", "text")).Output

    Write-Host "ERROR: Change set failed" -ForegroundColor Red
    Write-Host "Status : $csStatus"
    Write-Host "Reason : $csReason"

    Invoke-AwsCheck @("cloudformation", "delete-change-set", "--stack-name", $STACK_NAME, "--change-set-name", $CHANGE_SET_NAME, "--region", $REGION) | Out-Null
    if ($CHANGE_SET_TYPE -eq "CREATE") {
        Invoke-AwsCheck @("cloudformation", "delete-stack", "--stack-name", $STACK_NAME, "--region", $REGION) | Out-Null
    }
    exit 1
}

# ── Show change set summary ────────────────────────────────────────────────
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Change Set Summary:" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
& aws cloudformation describe-change-set `
    --stack-name $STACK_NAME `
    --change-set-name $CHANGE_SET_NAME `
    --region $REGION `
    --query "Changes[*].[Type, ResourceChange.Action, ResourceChange.LogicalResourceId, ResourceChange.ResourceType]" `
    --output table

# ── AUTO MODE ──────────────────────────────────────────────────────────────
if ($Auto) {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "AUTO MODE: Executing change set..." -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    & aws cloudformation execute-change-set `
        --stack-name $STACK_NAME `
        --change-set-name $CHANGE_SET_NAME `
        --region $REGION

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: execute-change-set failed" -ForegroundColor Red
        exit 1
    }

    Write-Host "Waiting for stack to complete (5-10 minutes)..." -ForegroundColor Yellow
    if ($CHANGE_SET_TYPE -eq "CREATE") {
        & aws cloudformation wait stack-create-complete --stack-name $STACK_NAME --region $REGION
    } else {
        & aws cloudformation wait stack-update-complete --stack-name $STACK_NAME --region $REGION
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Stack did not reach complete state" -ForegroundColor Red
        & aws cloudformation describe-stack-events `
            --stack-name $STACK_NAME `
            --region $REGION `
            --query "StackEvents[?ResourceStatus=='CREATE_FAILED' || ResourceStatus=='UPDATE_FAILED'].[LogicalResourceId,ResourceStatusReason]" `
            --output table
        exit 1
    }

    Write-Host "OK: Stack $CHANGE_SET_TYPE complete" -ForegroundColor Green

    # ── Seed sample data ───────────────────────────────────────────────────
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Seeding sample data into S3..." -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $seedFiles = @(
        @("POC\data\vehicle-models.csv", "avag-vehicles/vehicle-models/"),
        @("POC\data\sales.csv",          "avag-vehicles/sales/"),
        @("POC\data\dealerships.csv",    "avag-vehicles/dealerships/")
    )

    foreach ($pair in $seedFiles) {
        $localFile = $pair[0]
        $s3Key     = $pair[1]
        if (Test-Path $localFile) {
            Write-Host "  Uploading $localFile..."
            & aws s3 cp $localFile "s3://$PRIMARY_DATA_BUCKET_NAME/$s3Key" --region $REGION
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  OK: $s3Key" -ForegroundColor Green
            } else {
                Write-Host "  WARNING: Failed to upload $localFile" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  WARNING: File not found: $localFile" -ForegroundColor Yellow
        }
    }

    # ── GitHub OIDC (optional) ─────────────────────────────────────────────
    if ($WithCicd) {
        Write-Host ""
        Write-Host "==========================================" -ForegroundColor Cyan
        Write-Host "Setting up GitHub Actions OIDC..." -ForegroundColor Cyan
        Write-Host "==========================================" -ForegroundColor Cyan

        $gitRemoteCheck = Invoke-AwsCheck @()
        $old = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        $gitRemote = git remote get-url origin 2>$null
        $gitExit = $LASTEXITCODE
        $ErrorActionPreference = $old

        if ($gitExit -ne 0 -or [string]::IsNullOrWhiteSpace($gitRemote)) {
            Write-Host "ERROR: No git origin remote found." -ForegroundColor Red
            Write-Host "  Set it first:"
            Write-Host "    git remote add origin https://github.com/OWNER/REPO.git"
            Write-Host "    git push -u origin main"
            exit 1
        }

        $gitRemote = $gitRemote.Trim().TrimEnd('/') -replace '\.git$', ''
        if ($gitRemote -match "github\.com[/:]([^/]+)/([^/]+)$") {
            $githubOrg  = $Matches[1]
            $githubRepo = $Matches[2]
            Write-Host "  GitHub repo: $githubOrg/$githubRepo"
        } else {
            Write-Host "ERROR: Could not parse GitHub org/repo from: $gitRemote" -ForegroundColor Red
            exit 1
        }

        $OIDC_STACK = "github-actions-oidc"
        Write-Host "  Deploying OIDC stack..."

        & aws cloudformation deploy `
            --template-file cloudformation-github-oidc.yml `
            --stack-name $OIDC_STACK `
            --capabilities CAPABILITY_NAMED_IAM `
            --region $REGION `
            --no-fail-on-empty-changeset `
            --parameter-overrides "GitHubOrg=$githubOrg" "GitHubRepo=$githubRepo"

        if ($LASTEXITCODE -eq 0) {
            $roleArnCheck = Invoke-AwsCheck @("cloudformation", "describe-stacks", "--stack-name", $OIDC_STACK, "--region", $REGION, "--query", "Stacks[0].Outputs[?OutputKey=='DeployRoleArn'].OutputValue", "--output", "text")
            $roleArn = $roleArnCheck.Output.Trim()
            Write-Host "  OK: OIDC role: $roleArn" -ForegroundColor Green

            $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
            if ($ghCmd) {
                $old2 = $ErrorActionPreference
                $ErrorActionPreference = "SilentlyContinue"
                gh secret set AWS_DEPLOY_ROLE_ARN --repo "$githubOrg/$githubRepo" --body $roleArn 2>$null
                $ghSecretExit = $LASTEXITCODE
                $ErrorActionPreference = $old2
                if ($ghSecretExit -eq 0) {
                    Write-Host "  OK: GitHub secret AWS_DEPLOY_ROLE_ARN set" -ForegroundColor Green
                } else {
                    Write-Host "  WARNING: Could not set GitHub secret automatically" -ForegroundColor Yellow
                    Write-Host "    Run: gh secret set AWS_DEPLOY_ROLE_ARN --repo '$githubOrg/$githubRepo' --body '$roleArn'"
                }
            } else {
                Write-Host ""
                Write-Host "  INFO: gh CLI not found. Set the secret manually:" -ForegroundColor Yellow
                Write-Host "    1. Go to: https://github.com/$githubOrg/$githubRepo/settings/secrets/actions"
                Write-Host "    2. New repository secret"
                Write-Host "       Name  : AWS_DEPLOY_ROLE_ARN"
                Write-Host "       Value : $roleArn"
            }

            Write-Host ""
            Write-Host "==========================================" -ForegroundColor Cyan
            Write-Host "NEXT STEP: Push to GitHub to build the image" -ForegroundColor Cyan
            Write-Host "==========================================" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  git push origin main"
            Write-Host ""
            Write-Host "  Watch progress: https://github.com/$githubOrg/$githubRepo/actions"
        } else {
            Write-Host "  WARNING: OIDC stack deploy failed (non-blocking)" -ForegroundColor Yellow
        }
    } else {
        Write-Host ""
        Write-Host "INFO: Skipped GitHub OIDC setup." -ForegroundColor Yellow
        Write-Host "  To enable push-to-deploy, re-run with: .\deploy-changeset.ps1 -Auto -WithCicd"
    }

    # ── Glue crawlers ──────────────────────────────────────────────────────
    # Crawlers are NOT created by CloudFormation (CreateCrawlers=false).
    # The Lambda trigger creates and runs them automatically on S3 upload.
    Write-Host ""
    Write-Host "INFO: Glue crawlers will be created by the Lambda trigger on S3 upload" -ForegroundColor Yellow
    Write-Host "      (wait ~2 minutes after seeding completes)"

    $crawlerName = "avag-vehicles-crawler"
    $crawlerCheck = Invoke-AwsCheck @("glue", "get-crawler", "--name", $crawlerName, "--region", $REGION, "--query", "Crawler.State", "--output", "text")

    if ($crawlerCheck.Success -and $crawlerCheck.Output.Trim() -eq "READY") {
        Write-Host "  Found existing crawler '$crawlerName' — starting it now..."
        Invoke-AwsCheck @("glue", "start-crawler", "--name", $crawlerName, "--region", $REGION) | Out-Null
        Write-Host "  OK: Crawler started" -ForegroundColor Green
    } elseif ($crawlerCheck.Success) {
        Write-Host "  Crawler '$crawlerName' is in state '$($crawlerCheck.Output.Trim())' — Lambda will handle it"
    } else {
        Write-Host "  Crawler '$crawlerName' not yet created — Lambda will create it on S3 upload"
    }

    # ── Print final outputs ────────────────────────────────────────────────
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "DEPLOYMENT COMPLETE" -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green

    $albCheck = Invoke-AwsCheck @("cloudformation", "describe-stacks", "--stack-name", $STACK_NAME, "--region", $REGION, "--query", "Stacks[0].Outputs[?OutputKey=='LoadBalancerUrl'].OutputValue", "--output", "text")
    $albUrl = $albCheck.Output.Trim()

    $stlCheck = Invoke-AwsCheck @("cloudformation", "describe-stacks", "--stack-name", $STACK_NAME, "--region", $REGION, "--query", "Stacks[0].Outputs[?OutputKey=='StreamlitUrl'].OutputValue", "--output", "text")
    $streamlitUrl = $stlCheck.Output.Trim()

    if ($albUrl -and $albUrl -ne "None") {
        Write-Host "API URL   : $albUrl"
        Write-Host "Health    : $albUrl/health"
        Write-Host "Query ex  : see README or use Postman/curl"
    }
    if ($streamlitUrl -and $streamlitUrl -ne "None") {
        Write-Host "Streamlit : $streamlitUrl"
        Write-Host "Password  : aws secretsmanager get-secret-value --secret-id cgs-ai-analyst-agent/streamlit-credentials --region $REGION --query SecretString --output text"
    }

    Write-Host ""
    Write-Host "-- Optional next steps --"
    if (-not $WithDatabases) {
        Write-Host "  Add Aurora + Redshift : .\deploy-changeset.ps1 -Auto -WithDatabases"
    }
    if (-not $WithCicd) {
        Write-Host "  Enable CI/CD          : .\deploy-changeset.ps1 -Auto -WithCicd"
    }
    Write-Host "  Rebuild image (GitHub) : gh workflow run build-and-push-image"
    Write-Host "  Tear everything down   : .\teardown.ps1"

} else {
    # ── REVIEW MODE ────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Next Steps:" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host '  Option A - Run everything automatically:'
    Write-Host '    .\deploy-changeset.ps1 -Auto'
    Write-Host ''
    Write-Host '  Option B - With GitHub CI/CD (no local Docker):'
    Write-Host '    .\deploy-changeset.ps1 -Auto -WithCicd'
    Write-Host ''
    Write-Host '  Option C - Execute this change set manually:'
    Write-Host "    aws cloudformation execute-change-set"
    Write-Host "      --stack-name $STACK_NAME"
    Write-Host "      --change-set-name $CHANGE_SET_NAME"
    Write-Host "      --region $REGION"
    Write-Host ''
    Write-Host '  To delete this change set without executing:'
    Write-Host "    aws cloudformation delete-change-set"
    Write-Host "      --stack-name $STACK_NAME"
    Write-Host "      --change-set-name $CHANGE_SET_NAME"
    Write-Host "      --region $REGION"
    Write-Host ''
}
