# Fils Azure infrastructure (Bicep)

- `main.bicep` wires these modules: network (VNet, delegated Postgres subnet, private DNS), monitoring
  (Log Analytics + App Insights), identity (user-assigned MI), keyvault (RBAC, Secrets User role
  only), acr (AcrPull role), storage (private, MI-only, 1-day lifecycle), postgres (Flexible
  Server, VNet-only, TLS enforced), containerapps (API with probes and HTTP scaling, worker,
  manual migrate job).
- `params/staging.bicepparam` and `params/production.bicepparam`: the Postgres admin password comes
  from the `FILS_PG_ADMIN_PASSWORD` environment variable.
- `deploy.sh`: two-pass deployment (infra, then secrets and image, then apps), plus migrate, shift and
  rollback. It always runs `what-if` first.

Validation status: the templates have **not** been compiled with `bicep build` in this environment,
because downloading the Bicep CLI was not permitted. Run `az bicep build -f main.bicep` and
`az deployment group what-if` before the first deployment. See `../../docs/deployment.md`.
