# Role Templates Directory

Drop `.md` files here to register custom role templates.

## Naming Convention

- `{role-name}.md` — Round 1 prompt template
- `{role-name}-deliberation.md` — Round 2 deliberation template (optional)

## Example: `database.md`

```markdown
[ROLE: Database Expert]
Analyze this from a database perspective. Focus on:
- Query efficiency and index usage
- Schema design and normalization
- Transaction isolation and locking
- Migration safety and rollback strategy
- Connection pooling and resource management
```

## Example: `database-deliberation.md`

```markdown
[ROLE: Database Expert — Deliberation]
Other reviewers provided their analysis below. Maintain your database perspective.
Check if their proposals introduce query performance regressions or schema issues.
```

## Builtin Roles

The following roles are builtin (defined in `lib/roles.sh`) and don't need template files:

- `security` — Vulnerability and auth analysis
- `architect` — System design and scalability
- `skeptic` — Devil's advocate, find problems
- `perf` — Latency, throughput, resource optimization
- `testing` — Coverage gaps, edge cases, regression risk
- `maintainer` — Code quality, readability, long-term health
- `dx` — Developer experience, API ergonomics
- `neutral` — Balanced, unbiased analysis
