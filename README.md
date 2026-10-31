# Helm charts

Helm charts for [Backpack](https://github.com/linus-berg/backpack), published
to `https://linus-berg.github.io/helm-charts/` on every push to `main` that
bumps a chart version.

```bash
helm repo add backpack https://linus-berg.github.io/helm-charts/
helm repo update
```

| Chart | Description |
| :--- | :--- |
| [`backpack`](charts/backpack/README.md) | The Backpack API, GUI, gateway, collectors and processors. |

## Development

Bump `version` in the chart's `Chart.yaml` with every change. Every push to
`main` lints the charts and then publishes every chart whose version is not
released yet. Pull requests are linted too, and fail when a changed chart's
version was not bumped.

Linting runs [chart-testing](https://github.com/helm/chart-testing) with
each `charts/<chart>/ci/*-values.yaml` file and validates the rendered
manifests with [kubeconform](https://github.com/yannh/kubeconform). To run
the same locally:

```bash
docker run --rm -v "$PWD":/repo -w /repo quay.io/helmpack/chart-testing:v3.15.0 \
  sh -c "git config --global --add safe.directory '*' && ct lint --config ct.yaml --all"
helm template ci charts/backpack -f charts/backpack/ci/full-values.yaml \
  | docker run --rm -i ghcr.io/yannh/kubeconform:v0.8.0 -strict -summary
```
