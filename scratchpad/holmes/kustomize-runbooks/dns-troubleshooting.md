# DNS Resolution Troubleshooting

## Goal

Diagnose and resolve DNS resolution issues in Kubernetes clusters, including CoreDNS failures, pod DNS configuration problems, and service discovery issues.

## Workflow

1. Check CoreDNS pod status and logs for errors
2. Verify DNS resolution from the affected pod using nslookup or dig
3. Check the pod's `/etc/resolv.conf` for correct nameserver configuration
4. Verify the target Service exists and has endpoints
5. Check NetworkPolicies that may block DNS traffic on port 53
6. Review CoreDNS ConfigMap for custom configuration issues

## Synthesize Findings

- If CoreDNS pods are crashlooping, check resource limits and ConfigMap syntax
- If resolution works from CoreDNS pod but not from application pod, check NetworkPolicies
- If only external DNS fails, check CoreDNS forward plugin configuration
- If only specific services fail, verify the Service and Endpoints objects exist

## Recommended Remediation Steps

- Restart CoreDNS pods if they are in a bad state: `kubectl rollout restart deployment/coredns -n kube-system`
- Fix NetworkPolicies to allow egress to kube-dns on UDP/TCP port 53
- Verify CoreDNS ConfigMap syntax and reload: `kubectl rollout restart deployment/coredns -n kube-system`
- For ndots issues, consider adding `dnsConfig` to the pod spec to reduce unnecessary search domain lookups
