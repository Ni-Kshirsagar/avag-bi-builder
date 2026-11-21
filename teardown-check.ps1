# Teardown check script
$Results = @{}

# Step 1: List stacks
Write-Host "=== STEP 1: Discover Stacks ===" -ForegroundColor Cyan
try {
    $stacks = aws cloudformation list-stacks --region eu-north-1 --no-cli-pager --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query "StackSummaries[].StackName" --output text 2>&1
    Write-Host "Stacks found: $stacks"
    $Results['Stacks'] = $stacks
} catch {
    Write-Host "Error listing stacks: $_"
    $Results['Stacks'] = "Error: $_"
}

# Step 2: Check S3 buckets
Write-Host "`n=== STEP 2: Check S3 Buckets ===" -ForegroundColor Cyan
$buckets = @('langchain-276096488144-eu-north-1', 'cfn-templates-276096488144')
foreach ($bucket in $buckets) {
    try {
        aws s3api head-bucket --bucket $bucket --region eu-north-1 --no-cli-pager 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Bucket $bucket EXISTS"
            $Results[$bucket] = "EXISTS"
        } else {
            Write-Host "Bucket $bucket NOT FOUND"
            $Results[$bucket] = "NOT FOUND"
        }
    } catch {
        Write-Host "Bucket $bucket NOT FOUND (error)"
        $Results[$bucket] = "NOT FOUND"
    }
}

# Output results as JSON for parsing
Write-Host "`n=== RESULTS ===" -ForegroundColor Green
$Results | ConvertTo-Json
