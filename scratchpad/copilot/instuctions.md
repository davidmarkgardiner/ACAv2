```markdown
# Project Context
Brief description of what this project does, its purpose, and key architecture decisions.

# Tech Stack
- Primary languages: [e.g., Python 3.11, TypeScript]
- Frameworks: [e.g., FastAPI, Next.js 14]
- Key dependencies: [list major libraries]
- Infrastructure: [e.g., Kubernetes, Azure, AWS]

# Code Style & Standards
- Use [style guide name/link]
- Prefer [specific patterns, e.g., composition over inheritance]
- Max line length: [e.g., 120]
- Naming conventions: [snake_case, camelCase, etc.]
- Always include type hints/annotations
- Required linting: [e.g., pylint, eslint]

# Architecture Patterns
- Follow [pattern, e.g., hexagonal architecture, microservices]
- Keep business logic separate from infrastructure
- Use dependency injection for [services, repositories]
- Error handling: [approach, e.g., custom exceptions, Result types]

# Testing Requirements
- Write tests for all new functions
- Minimum coverage: [e.g., 80%]
- Test structure: [e.g., Arrange-Act-Assert, Given-When-Then]
- Mock external dependencies
- Include integration tests for [API endpoints, database operations]

# Security Considerations
- Never commit secrets or credentials
- Use environment variables for configuration
- Validate all user inputs
- Follow principle of least privilege
- [Any security frameworks or standards]

# Documentation
- Add docstrings to all public functions/classes
- Include examples in docstrings
- Update README when adding features
- Document breaking changes

# Git Workflow
- Branch naming: [e.g., feature/, bugfix/, hotfix/]
- Commit message format: [conventional commits, etc.]
- PR requirements: [tests pass, reviewed, etc.]

# Project-Specific Notes
[Any unique requirements, gotchas, or important context specific to this project]
```

For your **Kubernetes/platform engineering work**, you might want something more like:

```markdown
# Project Context
AKS platform infrastructure and GitOps configuration for enterprise environments.

# Tech Stack
- Kubernetes (AKS)
- GitOps: Argo CD, Argo Workflows, Argo Events
- Policy: Kyverno, OPA
- Service Mesh: Istio
- IaC: Terraform, Azure Service Operator
- Languages: Go, Python, YAML

# Kubernetes Standards
- Use Kustomize for overlays, not Helm templating
- All resources must include proper labels: app, version, component
- ResourceQuotas and LimitRanges required for all namespaces
- NetworkPolicies default-deny approach
- Use securityContext with non-root users
- Prefer StatefulSets for stateful workloads

# Security Requirements
- All images from approved registries only
- Pod Security Standards: restricted profile
- No privileged containers unless explicitly approved
- Use Workload Identity, not Service Principals
- seccomp profile: RuntimeDefault or Localhost
- All secrets via External Secrets Operator

# GitOps Patterns
- Single source of truth in Git
- No manual kubectl apply
- Use SemVer for releases
- Environments: dev -> test -> prod
- PR required for all changes

# Kyverno Policies
- Validate before apply
- Generate required resources automatically
- Use policy exceptions sparingly with justification
- Document policy intent in annotations

# Documentation
- Update ADRs for architectural decisions
- Include runbooks for operational procedures
- Document all exceptions to standards
```
