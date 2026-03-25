# Implementing the Weekly Cluster "Main Offenders" Report

Given your use of the **LGTM stack (Loki, Grafana, Tempo, Mimir/Metrics)** and the **Argo Workflows** infrastructure in your environment, you have two excellent paths to achieve this.

## Approach 1: The Native LGTM Way (Fastest to implement)
You can create a dedicated **"Cluster Offenders" Grafana Dashboard** and use Grafana's built-in tools.

1. **Dashboard Creation:** Create a dashboard dedicated exclusively to "worst metrics".
2. **Delivery:** If you use Grafana Enterprise, you can use the built-in [Reporting feature](https://grafana.com/docs/grafana/latest/dashboards/create-reports/) to email a PDF weekly. If you are on OSS, you can use a community tool like `grafana-reporter` or set up Grafana Alerting to trigger a webhook weekly with a snapshot link.

### Key PromQL Queries for the Dashboard:
* **Top CPU Over-Consumers (Usage > Requests):**
  ```promql
  topk(10, sum by (namespace, pod) (node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate) 
  / 
  sum by (namespace, pod) (kube_pod_container_resource_requests{resource="cpu"})) > 1.5
  ```
* **Highest Pod Restarts (Last 7 Days):**
  ```promql
  topk(10, increase(kube_pod_container_status_restarts_total[7d]) > 10)
  ```
* **Noisiest Namespaces (Kubernetes Warning Events):**
  *(Assuming you forward events to Loki)*
  ```logql
  topk(10, sum by (namespace) (count_over_time({job="kube-events"} |= "Warning" [7d])))
  ```

---

## Approach 2: The Agentic "Daily Web + Weekly Push" Approach (Recommended)
Since you are already using Argo Workflows, we can implement an automated agentic pipeline using a **CronWorkflow**. This approach allows you to generate a dynamic website and send customized Teams messages.

### How it works:
1. **Data Collection Job:** A Python container runs daily, queries the Mimir/Prometheus and Loki REST APIs for the PromQL/LogQL queries above.
2. **Report Generation:** The Python script templates the JSON responses into a Markdown or HTML file.
3. **Publishing:** 
   - The workflow commits the HTML to an internal Git repository (e.g., GitHub Pages) serving a static site (updated daily).
   - On Fridays, the workflow adds a step to POST the summarized Markdown to your Microsoft Teams webhook.

### Example Argo CronWorkflow (`application-stack/core/argo-workflows/weekly-offenders-report.yaml`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: weekly-cluster-offenders-report
  namespace: argo
spec:
  schedule: "0 8 * * 5" # Every Friday at 8:00 AM
  timezone: "UTC"
  startingDeadlineSeconds: 0
  concurrencyPolicy: "Replace"
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  workflowSpec:
    entrypoint: generate-and-send-report
    templates:
      - name: generate-and-send-report
        steps:
          - - name: fetch-metrics
              template: query-lgtm-apis
          - - name: send-teams-message
              template: notify-teams
              arguments:
                parameters:
                  - name: report-content
                    value: "{{steps.fetch-metrics.outputs.parameters.report}}"
          - - name: update-static-site
              template: push-to-git
              arguments:
                parameters:
                  - name: report-content
                    value: "{{steps.fetch-metrics.outputs.parameters.report}}"

      - name: query-lgtm-apis
        script:
          image: python:3.9-slim
          command: [python]
          source: |
            import requests, json
            
            # 1. Query Mimir/Prometheus API
            MIMIR_URL = "http://mimir-gateway.monitoring.svc:8080/prometheus/api/v1/query"
            query = 'topk(5, increase(kube_pod_container_status_restarts_total[7d]))'
            resp = requests.get(MIMIR_URL, params={'query': query})
            
            # 2. Format the data
            report = "# 🚨 Weekly AKS Cluster Offenders Report\n\n"
            report += "### Top 5 Pod Restarts (Last 7 Days):\n"
            
            if resp.status_code == 200:
                results = resp.json().get('data', {}).get('result', [])
                for r in results:
                    pod = r['metric'].get('pod', 'unknown')
                    ns = r['metric'].get('namespace', 'unknown')
                    count = round(float(r['value'][1]))
                    report += f"- **{ns}/{pod}**: {count} restarts\n"
            
            # 3. Output for the next step
            with open('/tmp/report.md', 'w') as f:
                f.write(report)
        outputs:
          parameters:
            - name: report
              valueFrom:
                path: /tmp/report.md

      - name: notify-teams
        inputs:
          parameters:
            - name: report-content
        container:
          image: curlimages/curl:latest
          command: [sh, -c]
          args:
            - |
              # Convert Markdown to JSON payload for Teams webhook
              # Note: Needs a valid webhook URL in a secret
              curl -H "Content-Type: application/json" \
                   -d "{\"text\": \"$(cat /tmp/content | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')\"}" \
                   $TEAMS_WEBHOOK_URL
          env:
            - name: TEAMS_WEBHOOK_URL
              valueFrom:
                secretKeyRef:
                  name: teams-webhook-secret
                  key: url
```

### Recommendation Summary
If you want **low effort today**, build a Grafana Dashboard and share the link weekly.
If you want a **modern, agentic approach** that feeds directly into a web portal and Teams chat natively (avoiding people needing to log into Grafana), implement the **Argo CronWorkflow** above. It integrates perfectly with your existing platform architecture!
