# Repo layout: config/ and scripts/

- `config/configuration.yaml` — charts-build-scripts options (validation
  source, Helm repo CNAME).
- `scripts/` — `chart-dir.sh` (resolves a package's working dir), `pull-*.sh`
  (download pinned tool binaries into `bin/` on demand, gitignored),
  `kyverno-policy-check.sh`, `check-image-availability.sh`,
  `check-package-version-bump.sh`, `changed-packages.sh`. `scripts/version`
  pins every tool version used by `make` and CI.
