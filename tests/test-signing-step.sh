#!/usr/bin/env bash
# Runs the "Use one fixed signing key" step of AIy's generated build workflow against four kinds of repositories
# (plain, *.keystore ignored, protected branch, second build). Needs: bash, git, keytool, python3 + PyYAML,
# and a workflow file as the first argument (generate it with logic/workflows.dart: workflowFor(ProjectKind.gradle)).
set -u
wf="$1"; work=$(mktemp -d); cd "$work"
python3 - "$wf" > step.sh <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print([s for s in d['jobs']['build']['steps'] if s.get('name') == 'Use one fixed signing key'][0]['run'])
PY
export GITHUB_REF_NAME=main
mk() { git init -q --bare o$1.git; git clone -q o$1.git r$1 2>/dev/null; (cd r$1; git checkout -q -b main; echo x > a; [ -n "$2" ] && printf "$2" > .gitignore; git add -A; git -c user.name=t -c user.email=t@t commit -qm i; git push -q origin main 2>/dev/null); }
mk A '*.keystore\n'; mk B '*.jks\n.aiy/\n'; mk C ''; mk D ''
printf '#!/bin/sh\nexit 1\n' > oD.git/hooks/pre-receive; chmod +x oD.git/hooks/pre-receive
bad=0
for r in A B C D; do (cd r$r; rm -f ~/.android/debug.keystore; bash -e ../step.sh >/dev/null 2>&1) || { echo "FAIL repo $r"; bad=1; }; done
[ $bad = 0 ] && echo "signing step: all 4 cases passed"
exit $bad
