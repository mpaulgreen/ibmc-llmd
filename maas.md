# This file is not for this project

JWT groups Claim: Keycloak vs IBM Verify — AuthPolicy Impact                                                                                                                                                                                        
                                                                                                                                                                                                                                                      
  The fundamental incompatibility between Keycloak and IBM Verify lies in how each identity provider serializes the groups claim within the JWT payload. This difference propagates through the entire Kuadrant AuthPolicy authorization chain.       
              
  Keycloak encodes groups as a JSON array ("groups": ["tenant-a-admins", "tenant-a-developers"]), which is the OIDC-standard multi-valued claim format. IBM Verify encodes groups as a scalar JSON string ("groups": "tenant-a-admins"), meaning only
  a single group membership is represented per token — a non-standard behavior.

  This divergence has three downstream consequences:

  1. OPA Rego evaluation — Keycloak requires array iteration (some i; group := input.auth.identity.groups[i]) to match tenant membership across multiple groups. IBM Verify uses direct string comparison (startswith(input.auth.identity.groups,
  "tenant-a-")) since the claim is a primitive, not a collection.
  2. Metadata HTTP callout body — When forwarding groups to the MaaS tier-lookup API (which expects an array), Keycloak's array passes through natively (auth.identity.groups). IBM Verify's string must be explicitly wrapped in an array literal
  ([auth.identity.groups]) to satisfy the API contract.
  3. Template selection — These differences are irreconcilable at runtime, requiring separate AuthPolicy templates per provider (authpolicy-keycloak.yaml.tpl vs authpolicy-ibmverify.yaml.tpl). Swapping identity providers requires re-deploying
  every tenant's AuthPolicy — the policies are not provider-agnostic.

  In short: the groups claim type mismatch (array vs string) makes the two providers non-interchangeable at the authorization policy layer without template-level branching.




------



Pending Items by Category

  1. Human Reviewer Asks (kwozyman) -- ADDRESSED but needs confirmation

  ┌────────────────────────────────────────────────────────────────┬─────────────────────────────────────────────────┐
  │                              Ask                               │                     Status                      │
  ├────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────┤
  │ Port rhcl-pre-deploy-check.sh into Python validation framework │ tsisodia10 added tests to llmd_xks_preflight.py │
  ├────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────┤
  │ Update READMEs (main + validation/)                            │ tsisodia10 updated both                         │
  ├────────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────┤
  │ kwozyman said "looks okay but I did not test"                  │ Awaiting kwozyman's actual test/lgtm            │
  └────────────────────────────────────────────────────────────────┴─────────────────────────────────────────────────┘

  2. Human Reviewer Asks (aneeshkp) -- ADDRESSED

  ┌──────────────────────────────────────────────────────────────────────────┬────────────────────────┐
  │                                   Ask                                    │         Status         │
  ├──────────────────────────────────────────────────────────────────────────┼────────────────────────┤
  │ Hardcoded mpaul path in copy-crds.sh                                     │ Fixed/removed          │
  ├──────────────────────────────────────────────────────────────────────────┼────────────────────────┤
  │ Add config instructions to docs/deploying-llm-d-on-managed-kubernetes.md │ Section 8 added        │
  ├──────────────────────────────────────────────────────────────────────────┼────────────────────────┤
  │ OLM extractor / bundle-update support for version upgrades               │ update-bundle.sh added │
  └──────────────────────────────────────────────────────────────────────────┴────────────────────────┘

  3. Unresolved CodeRabbit Findings (29 major, 4 minor)

  These are the substantive items still pending:

  Security (Critical/High):
  - OIDCPolicy.clientSecret exposed as plain text in CRD (CWE-312) -- this is an upstream CRD issue, likely won't be fixed in chart
  - Authorino RBAC grants cluster-wide create/delete on clusterroles/clusterrolebindings (CWE-269) -- unresolved, file rbac/authorino-operator-rbac.yaml line 40-42
  - podSecurityContext override drops hardening baseline -- resolved (commit 84aabd2)
  - Empty {} podSecurityContext disables hardening -- resolved (commit 84aabd2)
  - Shell injection in helmfile hooks -- resolved (commit 84aabd2)
  - Namespace cleanup deletes without ownership check -- resolved (commit 84aabd2)

  Schema Validation (Medium):
  - TLS policy privateKey.size accepts any integer, needs algorithm-specific constraints -- unresolved (upstream CRD)
  - Rate limit fields missing minimum: 0 -- unresolved (upstream CRD)
  - DNS hostname regex accepts invalid chars -- unresolved (upstream CRD)
  - Port fields missing 0-65535 range validation -- unresolved (upstream CRD)

  Operational (Medium):
  - Validation scripts: TIMEOUT defined but unused, single-point checks without polling
  - Instance name hardcoded in validation instead of using configured values
  - rhclOperator.enabled: true default (should it be false for "optional"?)
  - Pull secret create: true with empty dockerConfigJson causes silent ImagePullBackOff
  - Image helper template allows mutable tag fallback when digest missing

  4. Merge Blockers

  ┌─────────────────────────────────────┬───────────────────────────────────────┐
  │               Blocker               │                Status                 │
  ├─────────────────────────────────────┼───────────────────────────────────────┤
  │ Needs lgtm label                    │ Missing -- no reviewer has given lgtm │
  ├─────────────────────────────────────┼───────────────────────────────────────┤
  │ Needs approval from evacchi (OWNER) │ Not yet approved                      │
  ├─────────────────────────────────────┼───────────────────────────────────────┤
  │ kwozyman has not formally approved  │ "looks okay but did not test"         │
  └─────────────────────────────────────┴───────────────────────────────────────┘

  ---
  What Actually Needs Action

  Must-do for merge:
  1. Get lgtm from kwozyman or aneeshkp (they seem satisfied but haven't formally approved)
  2. Get approval from evacchi (OWNER)

  Should address before merge:
  3. RBAC overpermissioning on authorino-operator (cluster-wide clusterrole mutations) -- consider whether this is required by the operator or can be scoped down
  4. Default rhclOperator.enabled value -- if the intent is "optional", should default to false
  5. Pull secret empty dockerConfigJson failure mode -- add validation or document the requirement

  Upstream CRD issues (can defer):
  6. CRD schema validation gaps (privateKey.size, rate limits, DNS hostname, ports) -- these come from upstream OLM bundles and would be overwritten on next update. Document as known upstream limitations rather than patching.