#!/bin/sh
# Adapted from: https://gist.github.com/Willsr71/e4884be88f98b4c298692975c0ec8edb

github_token=$1
owner=$2
repo=$3
pr_number=$4
workflow_name=$5
artifact_name=$6

echo "Getting latest artifact for ${owner}/${repo} with workflow name {$workflow_name} and artifact name {$artifact_name}"

# debug
curl -s \
    -H "Authorization: Bearer ${github_token}" \
    https://api.github.com/repos/${owner}/${repo}/actions/workflows
# debug

latest_workflow_id=$(curl -s \
    -H "Authorization: Bearer ${github_token}" \
    https://api.github.com/repos/${owner}/${repo}/actions/workflows \
    | jq '.workflows[] | select(.name=="'${workflow_name}'").id')
echo "Latest workflow ID: ${latest_workflow_id}"

# debug
curl -s \
    -H "Authorization: Bearer ${github_token}" \
    https://api.github.com/repos/${owner}/${repo}/actions/workflows/${latest_workflow_id}/runs
# debug

latest_workflow_run_id=$(curl -s \
    -H "Authorization: Bearer ${github_token}" \
    https://api.github.com/repos/${owner}/${repo}/actions/workflows/${latest_workflow_id}/runs \
		| jq '[.workflow_runs[] | select(.status=="completed" and .conclusion=="success" and (.pull_requests | any(.number=="'${$pr_number}'")))] | sort_by(.updated_at) | reverse[0].id')
echo "Latest workflow run ID: ${latest_workflow_run_id}"

# debug
curl -s \
    -H "Authorization: Bearer ${github_token}" \
    https://api.github.com/repos/${owner}/${repo}/actions/runs/${latest_workflow_run_id}/artifacts
# debug

latest_artifact_id=$(curl -s \
    -H "Authorization: Bearer ${github_token}" \
    https://api.github.com/repos/${owner}/${repo}/actions/runs/${latest_workflow_run_id}/artifacts \
    | jq '.artifacts[] | select(.name=="'${artifact_name}'").id')
echo "Latest workflow ID: ${latest_artifact_id}"

curl -L -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${github_token}" \
    -o ${artifact_name}.zip https://api.github.com/repos/${owner}/${repo}/actions/artifacts/${latest_artifact_id}/zip
