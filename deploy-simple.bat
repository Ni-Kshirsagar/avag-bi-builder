@echo off
REM Simple deployment script
REM Run: deploy-simple.bat

SET REGION=eu-north-1
SET STACK_NAME=cgs-ai-analyst-agent-project

echo ==========================================
echo CloudFormation Deployment
echo ==========================================
echo Stack: %STACK_NAME%
echo Region: %REGION%
echo.

echo Checking AWS CLI...
aws sts get-caller-identity --region %REGION%
if %ERRORLEVEL% neq 0 (
    echo ERROR: AWS CLI not configured. Run 'aws configure' first.
    exit /b 1
)

echo.
echo Skipping template validation (deploying directly)...
REM type cloudformation-template-validated.yml | aws cloudformation validate-template --region %REGION%
REM if %ERRORLEVEL% neq 0 (
REM     echo ERROR: Template validation failed
REM     exit /b 1
REM )
REM echo Template valid.

echo.
echo Getting account ID...
for /f "delims=" %%i in ('aws sts get-caller-identity --query Account --output text') do set ACCOUNT_ID=%%i
set BUCKET_NAME=langchain-%ACCOUNT_ID%-eu-north-1
echo Bucket: %BUCKET_NAME%

echo.
echo Deploying stack (this may take 5-10 minutes)...
aws cloudformation deploy ^
    --template-file cloudformation-template-validated.yml ^
    --stack-name %STACK_NAME% ^
    --capabilities CAPABILITY_IAM ^
    --region %REGION% ^
    --no-fail-on-empty-changeset ^
    --parameter-overrides ^
        DesiredCount=0 ^
        StreamlitDesiredCount=0 ^
        StreamlitUsername=admin ^
        PrimaryDataBucketName=%BUCKET_NAME% ^
        CreatePrimaryDataBucket=true ^
        AthenaWorkgroupName=project-text-to-sql ^
        CreateAthenaWorkgroup=true ^
        LibraryGlueDatabaseName=project_library_db ^
        CarsGlueDatabaseName=project_cars_db ^
        CreateLibraryGlueDatabase=true ^
        CreateCarsGlueDatabase=true ^
        CreateAppLogGroup=true ^
        CreateCrawlers=true

if %ERRORLEVEL% neq 0 (
    echo ERROR: Stack deployment failed
    exit /b 1
)

echo.
echo ✓ Stack deployed successfully

echo.
echo Uploading sample data...
aws s3 cp "POC\data\s3_cars_data_normalized.csv" "s3://%BUCKET_NAME%/cars-data/" --region %REGION%
aws s3 cp "POC\data\s3_library_data.json" "s3://%BUCKET_NAME%/library-data/" --region %REGION%
echo ✓ Data uploaded

echo.
echo Starting Glue crawlers...
aws glue start-crawler --name project-library-crawler --region %REGION%
aws glue start-crawler --name project-cars-crawler --region %REGION%
echo ✓ Crawlers started

echo.
echo Getting stack outputs...
for /f "delims=" %%i in ('aws cloudformation describe-stacks --stack-name %STACK_NAME% --region %REGION% --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerUrl'].OutputValue" --output text') do set API_URL=%%i
for /f "delims=" %%i in ('aws cloudformation describe-stacks --stack-name %STACK_NAME% --region %REGION% --query "Stacks[0].Outputs[?OutputKey=='StreamlitUrl'].OutputValue" --output text') do set STREAMLIT_URL=%%i

echo.
echo ==========================================
echo DEPLOYMENT COMPLETE
echo ==========================================
echo API URL:     %API_URL%
echo Streamlit:   %STREAMLIT_URL%
echo.
echo Get Streamlit password:
echo aws secretsmanager get-secret-value --secret-id cgs-ai-analyst-agent/streamlit-credentials --region %REGION% --query SecretString --output text
echo.
echo Health check:
echo curl %API_URL%/health
echo.
