#!/bin/sh
# Adapted from: https://gist.github.com/Willsr71/e4884be88f98b4c298692975c0ec8edb

github_token=$1
# NOTE: repository is the full name, e.g. owner/repo
repository=$2
pr_number=$3
branch_name=$4
workflow_name=$5
artifact_name=$6

echo "Getting latest artifact for ${repository} with workflow name {$workflow_name} and artifact name {$artifact_name}"
echo "PR number: ${pr_number} - branch name: ${branch_name}"

# debug
curl -s \
    -H "Authorization: Bearer ${github_token}" \
    https://api.github.com/repos/${repository}/actions/workflows
# debug
echo "Authorization: Bearer ${github_token}"
echo "https://api.github.com/repos/${repository}/actions/workflows"

latest_workflow_id=$(curl -s \
    -H "Authorization: Bearer ${github_token}" \
    https://api.github.com/repos/${repository}/actions/workflows \
    | jq '.workflows[] | select(.name=="'${workflow_name}'").id')
echo "Latest workflow ID: ${latest_workflow_id}"

echo "this should be headed"
# debug
curl -s \
    -H "Authorization: Bearer ${github_token}" \
    https://api.github.com/repos/${repository}/actions/workflows/${latest_workflow_id}/runs?status=success&branch=${branch_name} | head -n 50
# debug
latest_workflow_run_id=$(curl -s \
    -H "Authorization: Bearer ${github_token}" \
    https://api.github.com/repos/${repository}/actions/workflows/${latest_workflow_id}/runs?status=success&branch=${branch_name} \
		| jq '([.workflow_runs[] | select(.pull_requests | any(.number == 129))] | max_by(.run_number)) | .id')
echo "Latest workflow run ID: ${latest_workflow_run_id}"

# debug
curl -s \
    -H "Authorization: Bearer ${github_token}" \
    https://api.github.com/repos/${repository}/actions/runs/${latest_workflow_run_id}/artifacts
# debug

latest_artifact_id=$(curl -s \
    -H "Authorization: Bearer ${github_token}" \
    https://api.github.com/repos/${repository}/actions/runs/${latest_workflow_run_id}/artifacts \
    | jq '.artifacts[] | select(.name=="'${artifact_name}'").id')
echo "Latest workflow ID: ${latest_artifact_id}"

curl -L -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${github_token}" \
    -o ${artifact_name}.zip https://api.github.com/repos/${repository}/actions/artifacts/${latest_artifact_id}/zip
