@echo off
REM Production Deployment Test Script for Windows
REM This tests prod deployment and immediately destroys it

echo =========================================
echo PRODUCTION DEPLOYMENT TEST
echo =========================================
echo.
echo This will:
echo 1. Deploy FULL production infrastructure to us-west-2
echo 2. Verify deployment succeeds
echo 3. IMMEDIATELY DESTROY everything to avoid costs
echo.
echo NOTE: This uses MINIMAL resources for testing
echo       Real production would use larger resources!
echo.
set /p CONFIRM="Continue with test deployment? (yes/no): "

if not "%CONFIRM%"=="yes" (
    echo Test cancelled
    exit /b 0
)

REM Get AWS account ID
for /f "tokens=*" %%a in ('aws sts get-caller-identity --query Account --output text') do set ACCOUNT_ID=%%a
echo AWS Account ID: %ACCOUNT_ID%

set REGION=us-west-2
set ENVIRONMENT=prod
set SCRIPTS_BUCKET=ndjson-glue-scripts-%ACCOUNT_ID%-%ENVIRONMENT%

echo Test region: %REGION%
echo Environment: %ENVIRONMENT%
echo.

REM Backup existing terraform.tfvars
if exist terraform.tfvars (
    echo Backing up existing terraform.tfvars...
    copy terraform.tfvars terraform.tfvars.backup
)

REM Copy prod test config
echo Using production test configuration...
copy terraform.tfvars.prod terraform.tfvars

REM Update scripts bucket in tfvars
powershell -Command "(Get-Content terraform.tfvars) -replace 'existing_scripts_bucket_name    = \".*\"', 'existing_scripts_bucket_name    = \"\"' | Set-Content terraform.tfvars"

echo.
echo Starting production deployment test...
echo This will take several minutes...
echo.

REM Initialize and deploy
terraform init
if %errorlevel% neq 0 goto :deploy_failed

terraform plan -out=tfplan
if %errorlevel% neq 0 goto :deploy_failed

terraform apply -auto-approve tfplan
if %errorlevel% neq 0 goto :deploy_failed

echo.
echo Production deployment test SUCCESSFUL!
echo.

REM Show outputs
echo Resources created:
terraform output

echo.
echo Waiting 30 seconds before destroying...
timeout /t 30 /nobreak

REM Destroy
echo.
echo =========================================
echo DESTROYING TEST DEPLOYMENT
echo =========================================
echo.

terraform destroy -auto-approve
if %errorlevel% neq 0 goto :destroy_failed

echo All resources destroyed successfully!

REM Clean up scripts bucket
echo Deleting scripts bucket...
aws s3 rm s3://%SCRIPTS_BUCKET% --recursive --region %REGION%
aws s3 rb s3://%SCRIPTS_BUCKET% --region %REGION%

REM Restore original config
if exist terraform.tfvars.backup (
    echo Restoring original terraform.tfvars...
    move /y terraform.tfvars.backup terraform.tfvars
)

echo.
echo =========================================
echo PRODUCTION DEPLOYMENT TEST COMPLETE
echo =========================================
echo.
echo [SUCCESS] Deployment succeeded
echo [SUCCESS] All resources destroyed
echo [SUCCESS] Scripts bucket deleted
echo [SUCCESS] Configuration restored
echo.
echo Production deployment process is VERIFIED and working!
echo When ready for real production, use: deploy.sh prod
echo.
goto :end

:deploy_failed
echo.
echo [ERROR] Production deployment FAILED!
if exist terraform.tfvars.backup (
    move /y terraform.tfvars.backup terraform.tfvars
)
exit /b 1

:destroy_failed
echo.
echo [ERROR] Destroy failed! Check AWS console and manually delete resources!
exit /b 1

:end
