$ErrorActionPreference = "Continue"
$REGION     = "eu-north-1"
$STACK      = "cgs-ai-analyst-agent-project"
$OIDC_STACK = "github-actions-oidc"
$ACCOUNT_ID = "276096488144"

Write-Host "=== Deleting failed change sets ===" -ForegroundColor Cyan
$csJson = aws cloudformation list-change-sets --stack-name $STACK --region $REGION --output json 2>&1
if ($LASTEXITCODE -eq 0) {
    $changeSets = ($csJson | ConvertFrom-Json).Summaries | ForEach-Object { $_.ChangeSetName }
    foreach ($cs in $changeSets) {
        Write-Host "  Deleting change set: $cs"
        aws cloudformation delete-change-set --stack-name $STACK --change-set-name $cs --region $REGION 2>&1
    }
} else {
    Write-Host "  No change sets found (stack may not exist)." -ForegroundColor Gray
}

Write-Host "`n=== Deleting main stack: $STACK ===" -ForegroundColor Cyan
$stackCheck = aws cloudformation describe-stacks --stack-name $STACK --region $REGION 2>&1
if ($LASTEXITCODE -eq 0) {
    aws cloudformation delete-stack --stack-name $STACK --region $REGION 2>&1
    Write-Host "Waiting for stack deletion (up to 10 min)..."
    aws cloudformation wait stack-delete-complete --stack-name $STACK --region $REGION 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Main stack deleted successfully." -ForegroundColor Green
    } else {
        Write-Host "Stack deletion timed out or failed — check CloudFormation console for details." -ForegroundColor Yellow
    }
} else {
    Write-Host "  Stack does not exist — skipping." -ForegroundColor Gray
}

Write-Host "`n=== Deleting OIDC stack: $OIDC_STACK ===" -ForegroundColor Cyan
$oidcCheck = aws cloudformation describe-stacks --stack-name $OIDC_STACK --region $REGION 2>&1
if ($LASTEXITCODE -eq 0) {
    aws cloudformation delete-stack --stack-name $OIDC_STACK --region $REGION 2>&1
    aws cloudformation wait stack-delete-complete --stack-name $OIDC_STACK --region $REGION 2>&1
    Write-Host "OIDC stack deleted." -ForegroundColor Green
} else {
    Write-Host "  OIDC stack does not exist — skipping." -ForegroundColor Gray
}

Write-Host "`n=== Checking for leftover ECR repositories ===" -ForegroundColor Cyan
$repoJson = aws ecr describe-repositories --region $REGION --output json 2>&1
if ($LASTEXITCODE -eq 0) {
    $repos = ($repoJson | ConvertFrom-Json).repositories | ForEach-Object { $_.repositoryName }
    if ($repos.Count -eq 0) {
        Write-Host "  No ECR repositories found." -ForegroundColor Gray
    } else {
        foreach ($repo in $repos) {
            Write-Host "  Deleting ECR repo: $repo"
            aws ecr delete-repository --repository-name $repo --region $REGION --force 2>&1
        }
    }
}

Write-Host "`n=== Checking for leftover S3 bucket ===" -ForegroundColor Cyan
$bucketName = "langchain-$ACCOUNT_ID-$REGION"
aws s3api head-bucket --bucket $bucketName 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Emptying bucket: $bucketName"
    aws s3 rm "s3://$bucketName" --recursive --region $REGION 2>&1
    Write-Host "  Deleting bucket: $bucketName"
    aws s3api delete-bucket --bucket $bucketName --region $REGION 2>&1
    Write-Host "  Bucket deleted." -ForegroundColor Green
} else {
    Write-Host "  Bucket $bucketName does not exist — skipping." -ForegroundColor Gray
}

Write-Host "`n=== Remaining stacks ===" -ForegroundColor Cyan
aws cloudformation describe-stacks --region $REGION --output json 2>&1 | ConvertFrom-Json | ForEach-Object {
    $_.Stacks | ForEach-Object { Write-Host "  $($_.StackName) : $($_.StackStatus)" }
}

Write-Host "`n=== Tear down complete ===" -ForegroundColor Green
