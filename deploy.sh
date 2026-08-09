#!/usr/bin/env bash
#
# deploy.sh — Build and deploy lambda_function.py to all four "Beyond_" Lambdas
# in us-west-2 (r/cybersecurity cross-post bots) using the AWS CLI.
#
# Responsibilities:
#   1. Build deploy_me.zip via build.sh (built for the Python 3.12 runtime)
#   2. Update every Beyond_* Lambda's code to python3.12
#   3. Set each Lambda's runtime to python3.12 (config only; environment
#      variables are never modified)
#   4. Verify deployments
#
# Credentials are retrieved from the named AWS CLI profile (stored in
# ~/.aws/credentials), so no secret material lives in this script.
#
# Usage: ./deploy.sh <aws-profile>   e.g. ./deploy.sh best-of-bot
#
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <aws-profile>" >&2
    echo "  e.g.  $0 best-of-bot" >&2
    exit 2
fi

AWS_PROFILE="$1"
export AWS_PROFILE

REGION="us-west-2"
RUNTIME="python3.12"

# The four Beyond_* Lambdas map to the subreddits they cross-post from.
declare -a FUNC_NAMES=(
    "Beyond_netsec"          # -> r/netsec
    "Beyond_blueteamsec"     # -> r/blueteamsec
    "Beyond_redteamsec"      # -> r/redteamsec
    "Beyond_purpleteamsec"   # -> r/purpleteamsec
)

echo "==> Using AWS CLI profile: $AWS_PROFILE"

# Step 1: build the deployment artifact
echo "==> Building deploy_me.zip"
bash ./build.sh

ZIP_FILE="deploy_me.zip"
if [[ ! -f "$ZIP_FILE" ]]; then
    echo "ERROR: $ZIP_FILE not found after build." >&2
    exit 1
fi

# Step 2 & 3: deploy code + runtime to each Lambda
for FUNC_NAME in "${FUNC_NAMES[@]}"; do
    echo ""
    echo "==> Deploying $FUNC_NAME ($REGION)"

    # Upload code FIRST (built for python3.12) so packaged extensions match
    # before switching the runtime, avoiding any import-mismatch window.
    # --publish omitted: keeps $LATEST, does not create/publish a new version.
    aws lambda update-function-code \
        --function-name "$FUNC_NAME" \
        --region "$REGION" \
        --zip-file "fileb://$ZIP_FILE" >/dev/null

    # Wait for the code update to finish before touching configuration (Lambda
    # only allows one in-progress update at a time).
    echo "   Waiting for code update to complete..."
    for _ in $(seq 1 40); do
        LU="$(aws lambda get-function-configuration \
            --function-name "$FUNC_NAME" \
            --region "$REGION" --query "LastUpdateStatus" --output text)"
        echo "   LastUpdateStatus=$LU"
        if [[ "$LU" == "Successful" ]]; then break; fi
        if [[ "$LU" == "Failed" ]]; then
            echo "ERROR: update failed for $FUNC_NAME." >&2
            exit 1
        fi
        sleep 3
    done

    echo "   Updating runtime to $RUNTIME"
    # Configuration only; environment variables are never modified.
    aws lambda update-function-configuration \
        --function-name "$FUNC_NAME" \
        --region "$REGION" \
        --runtime "$RUNTIME" >/dev/null
done

# Step 4: verify all four Lambdas
echo ""
echo "==> Verifying all Beyond_* Lambdas"
for FUNC_NAME in "${FUNC_NAMES[@]}"; do
    read -r ARN RT ST LU < <(
        AWS_PROFILE="$AWS_PROFILE" aws lambda get-function-configuration \
            --function-name "$FUNC_NAME" \
            --region "$REGION" \
            --query "[FunctionArn, Runtime, State, LastUpdateStatus]" \
            --output text
    )
    printf "   %-22s runtime=%-10s state=%-7s lastUpdate=%-10s\n" "$FUNC_NAME" "$RT" "$ST" "$LU"
done

echo "DONE"
