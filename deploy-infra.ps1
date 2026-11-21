$ErrorActionPreference = "Stop"

$ACCOUNT_ID  = "276096488144"
$REGION      = "eu-north-1"
$STACK_NAME  = "cgs-ai-analyst-agent-project"
$BUCKET      = "langchain-$ACCOUNT_ID-$REGION"
$TS          = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$CS_NAME     = "$STACK_NAME-cs-$TS"

Write-Host "=== Step 1: Create change set for main stack ===" -ForegroundColor Cyan
Write-Host "Stack  : $STACK_NAME"
Write-Host "Bucket : $BUCKET"
Write-Host "CS     : $CS_NAME"

aws cloudformation create-change-set `
  --stack-name $STACK_NAME `
  --change-set-name $CS_NAME `
  --change-set-type CREATE `
  --template-body file://cloudformation-template-validated.yml `
  --capabilities CAPABILITY_IAM `
  --region $REGION `
  --parameters `
    "ParameterKey=DesiredCount,ParameterValue=0" `
    "ParameterKey=StreamlitDesiredCount,ParameterValue=0" `
    "ParameterKey=PrimaryDataBucketName,ParameterValue=$BUCKET" `
    "ParameterKey=CreatePrimaryDataBucket,ParameterValue=true" `
    "ParameterKey=CreateAthenaWorkgroup,ParameterValue=true" `
    "ParameterKey=CreateLibraryGlueDatabase,ParameterValue=true" `
    "ParameterKey=CreateCarsGlueDatabase,ParameterValue=true" `
    "ParameterKey=CreateAppLogGroup,ParameterValue=true" `
    "ParameterKey=CreateCrawlers,ParameterValue=false" `
    "ParameterKey=StreamlitUsername,ParameterValue=admin" `
  --tags `
    "Key=DeployedBy,Value=Agentic_ai" `
    "Key=Environment,Value=production"

if ($LASTEXITCODE -ne 0) { Write-Error "create-change-set failed"; exit 1 }

Write-Host "`n=== Step 2: Waiting for change set to be ready ===" -ForegroundColor Cyan
aws cloudformation wait change-set-create-complete `
  --stack-name $STACK_NAME `
  --change-set-name $CS_NAME `
  --region $REGION

if ($LASTEXITCODE -ne 0) { Write-Error "change-set-create-complete wait failed"; exit 1 }

Write-Host "`n=== Step 3: Executing change set ===" -ForegroundColor Cyan
aws cloudformation execute-change-set `
  --stack-name $STACK_NAME `
  --change-set-name $CS_NAME `
  --region $REGION

if ($LASTEXITCODE -ne 0) { Write-Error "execute-change-set failed"; exit 1 }

Write-Host "`n=== Step 4: Waiting for stack CREATE_COMPLETE (this takes ~5 min) ===" -ForegroundColor Cyan
aws cloudformation wait stack-create-complete `
  --stack-name $STACK_NAME `
  --region $REGION

if ($LASTEXITCODE -ne 0) { Write-Error "Stack did not reach CREATE_COMPLETE"; exit 1 }

Write-Host "`n=== Stack deployed successfully! ===" -ForegroundColor Green
aws cloudformation describe-stacks `
  --stack-name $STACK_NAME `
  --region $REGION `
  --query "Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}" `
  --output table
