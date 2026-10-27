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
