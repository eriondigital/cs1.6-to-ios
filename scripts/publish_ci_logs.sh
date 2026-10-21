#!/usr/bin/env bash
#
# Pushes the files of a CI job (build logs, simulator screenshots, the IPA) to the
# "ci-logs" branch under runs/<run number>-<run id>/<job>/, so they can be fetched
# with plain git when the Actions log/artifact storage isn't reachable.
#
# usage (inside GitHub Actions): scripts/publish_ci_logs.sh <job name> <dir with files>
#
set -uo pipefail

JOB="$1"
SRC="$(cd "$2" && pwd)"
DEST="runs/${GITHUB_RUN_NUMBER}-${GITHUB_RUN_ID}/${JOB}"
WORK="$(mktemp -d)"

cd "$WORK" || exit 1
git init -q
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

for attempt in 1 2 3 4 5 6; do
	if git fetch -q --depth 1 origin ci-logs 2>/dev/null; then
		git checkout -q -f -B ci-logs FETCH_HEAD
	else
		git checkout -q -f --orphan ci-logs
		git rm -rqf . >/dev/null 2>&1 || true
		printf 'Build logs, simulator screenshots and test builds pushed by CI.\n' > README.md
	fi

	mkdir -p "$DEST"
	cp -R "$SRC"/. "$DEST"/
	git add -A
	git commit -qm "CI files: run ${GITHUB_RUN_NUMBER}, ${JOB}" || true

	if git push -q origin HEAD:ci-logs; then
		echo "published to ci-logs:$DEST"
		exit 0
	fi
	sleep $((attempt * 4))
done

echo "could not push to ci-logs" >&2
exit 1
