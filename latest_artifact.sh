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

workflows_url="https://api.github.com/repos/${repository}/actions/workflows"
workflows=$(curl -sS -H "Authorization: Bearer ${github_token}" "${workflows_url}")
latest_workflow_id=$(echo ${workflows} \
	| jq \
		--arg workflow_name "$workflow_name" \
		'.workflows[] | select(.name==$workflow_name).id' || echo "ERROR")

if [ "${latest_workflow_id}" = "ERROR" ]; then
	echoerr 'Failed to parse GitHub response with jq:'
	echoerr "(url: ${workflows_url})"
	echoerr "${workflows}"
	exit 0
fi

if [ "${latest_workflow_id}" = "null" ]; then
  echoerr "No workflow found with name ${workflow_name}"
  exit 0
fi
echoerr "Latest workflow ID: ${latest_workflow_id}"

workflow_runs_url="https://api.github.com/repos/${repository}/actions/workflows/${latest_workflow_id}/runs?status=success&branch=${branch_name}"
workflow_runs=$(curl -sS -H "Authorization: Bearer ${github_token}" "${workflow_runs_url}")
latest_workflow_run_id=$(\
	echo ${workflow_runs} \
	| jq \
		--argjson pr_number "${pr_number}" \
		'([.workflow_runs[] | select(.pull_requests | any(.number == $pr_number))] | max_by(.run_number)) | .id' || echo "ERROR")


if [ "${latest_workflow_run_id}" = "ERROR" ]; then
	echoerr 'Failed to parse GitHub response with jq:'
	echoerr "(url: ${workflow_runs_url})"
	echoerr "${workflow_runs}"
	exit 0
fi

if [ "${latest_workflow_run_id}" = "null" ]; then
  echoerr "No successful workflow run found for PR ${pr_number} on branch ${branch_name}"
  exit 0
fi
echoerr "Latest workflow run ID: ${latest_workflow_run_id}"

artifacts_url="https://api.github.com/repos/${repository}/actions/runs/${latest_workflow_run_id}/artifacts"
artifacts=$(curl -sS -H "Authorization: Bearer ${github_token}" "${artifacts_url}")
latest_artifact_id=$(echo ${artifacts} \
	| jq \
		--arg artifact_name "$artifact_name" \
		'.artifacts[] | select(.name==$artifact_name).id' || echo "ERROR")

if [ "${latest_artifact_id}" = "ERROR" ]; then
	echoerr 'Failed to parse GitHub response with jq:'
	echoerr "(url: ${artifacts_url})"
	echoerr "${artifacts}"
	exit 0
fi

if [ "${latest_artifact_id}" = "null" ]; then
  echoerr "No artifacts found for workflow run ${latest_workflow_run_id}"
  exit 0
fi
echoerr "Latest artifact ID: ${latest_artifact_id}"

curl -sSL -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${github_token}" \
    -o ${artifact_name}.zip https://api.github.com/repos/${repository}/actions/artifacts/${latest_artifact_id}/zip

unzip -q ${artifact_name}.zip

