#!/bin/sh
# Adapted from: https://gist.github.com/Willsr71/e4884be88f98b4c298692975c0ec8edb


github_token=$1
# NOTE: repository is the full name, e.g. owner/repo
repository=$2
pr_number=$3
branch_name=$4
workflow_name=$5
artifact_name=$6

echoerr() { echo "$@" 1>&2; }

# Exit on error with a zero exit code, as we don't want to fail the workflow
# The lack of file output will signal that there was no artifact to download
trap 'exit 0'

workflows=$(curl -sS \
	-H "Authorization: Bearer ${github_token}" \
	https://api.github.com/repos/${repository}/actions/workflows)
latest_workflow_id=$(echo ${workflows} \
	| jq '.workflows[] | select(.name=="'${workflow_name}'").id')
if [ "${latest_workflow_id}" == "null" ]; then
  echoerr "No workflow found with name ${workflow_name}"
  exit 0
fi
echoerr "Latest workflow ID: ${latest_workflow_id}"

workflow_runs=$(curl -sS \
    -H "Authorization: Bearer ${github_token}" \
		https://api.github.com/repos/${repository}/actions/workflows/${latest_workflow_id}/runs?status=success&branch=${branch_name})
latest_workflow_run_id=$(echo ${workflow_runs} \
		| jq '([.workflow_runs[] | select(.pull_requests | any(.number == '${pr_number}'))] | max_by(.run_number)) | .id')
if [ "${latest_workflow_run_id}" == "null" ]; then
  echoerr "No successful workflow run found for PR ${pr_number} on branch ${branch_name}"
  exit 0
fi
echoerr "Latest workflow run ID: ${latest_workflow_run_id}"

artifacts=$(curl -sS \
	-H "Authorization: Bearer ${github_token}" \
	https://api.github.com/repos/${repository}/actions/runs/${latest_workflow_run_id}/artifacts)
latest_artifact_id=$(echo ${artifacts} \
	| jq '.artifacts[] | select(.name=="'${artifact_name}'").id')
if [ "${latest_artifact_id}" == "null" ]; then
  echoerr "No artifacts found for workflow run ${latest_workflow_run_id}"
  exit 0
fi
echoerr "Latest artifact ID: ${latest_artifact_id}"

curl -sSL -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${github_token}" \
    -o ${artifact_name}.zip https://api.github.com/repos/${repository}/actions/artifacts/${latest_artifact_id}/zip

unzip -q ${artifact_name}.zip

