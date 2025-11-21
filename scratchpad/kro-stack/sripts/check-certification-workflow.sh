#!/bin/bash

# Script to check if KRO certification workflow has worked correctly
# Usage: ./check-certification-workflow.sh [cluster-name]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# Check if cluster name is provided
CLUSTER_NAME="${1:-}"
if [ -z "$CLUSTER_NAME" ]; then
    print_error "Cluster name not provided"
    echo "Usage: $0 <cluster-name>"
    echo ""
    print_info "Available UK8SClusterPublic instances:"
    kubectl get uk8sclusterpublic -A -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,CLUSTER:.spec.clusterName 2>/dev/null || echo "No instances found"
    exit 1
fi

# Check if jq is available (optional but useful)
JQ_AVAILABLE=false
if command -v jq &> /dev/null; then
    JQ_AVAILABLE=true
fi

print_header "Checking Certification Workflow for Cluster: $CLUSTER_NAME"

# Counter for checks
PASSED=0
FAILED=0
WARNINGS=0

# =====================================
# 1. Check WorkflowTemplate
# =====================================
print_header "1. WorkflowTemplate Check"

if kubectl get workflowtemplate "certify-${CLUSTER_NAME}" -n argo &>/dev/null; then
    print_success "WorkflowTemplate 'certify-${CLUSTER_NAME}' exists"
    PASSED=$((PASSED+1))

    # Show some details
    TEMPLATE_AGE=$(kubectl get workflowtemplate "certify-${CLUSTER_NAME}" -n argo -o jsonpath='{.metadata.creationTimestamp}')
    print_info "Created at: $TEMPLATE_AGE"

    # Check entrypoint
    ENTRYPOINT=$(kubectl get workflowtemplate "certify-${CLUSTER_NAME}" -n argo -o jsonpath='{.spec.entrypoint}')
    print_info "Entrypoint: $ENTRYPOINT"
else
    print_error "WorkflowTemplate 'certify-${CLUSTER_NAME}' not found"
    FAILED=$((FAILED+1))
fi

# =====================================
# 2. Check CronWorkflow (Schedule)
# =====================================
print_header "2. CronWorkflow Schedule Check"

if kubectl get cronworkflow "weekly-cert-${CLUSTER_NAME}" -n argo &>/dev/null; then
    print_success "CronWorkflow 'weekly-cert-${CLUSTER_NAME}' exists"
    PASSED=$((PASSED+1))

    SCHEDULE=$(kubectl get cronworkflow "weekly-cert-${CLUSTER_NAME}" -n argo -o jsonpath='{.spec.schedule}')
    SUSPENDED=$(kubectl get cronworkflow "weekly-cert-${CLUSTER_NAME}" -n argo -o jsonpath='{.spec.suspend}')
    print_info "Schedule: $SCHEDULE"

    if [ "$SUSPENDED" == "true" ]; then
        print_warning "CronWorkflow is SUSPENDED (this is expected initially)"
        WARNINGS=$((WARNINGS+1))
    else
        print_info "CronWorkflow is ACTIVE"
    fi
else
    print_error "CronWorkflow 'weekly-cert-${CLUSTER_NAME}' not found"
    FAILED=$((FAILED+1))
fi

# =====================================
# 3. Check Trigger Job
# =====================================
print_header "3. Certification Trigger Job Check"

if kubectl get job "trigger-cert-${CLUSTER_NAME}" -n argo &>/dev/null; then
    print_success "Trigger Job 'trigger-cert-${CLUSTER_NAME}' exists"
    PASSED=$((PASSED+1))

    # Check job status
    JOB_SUCCEEDED=$(kubectl get job "trigger-cert-${CLUSTER_NAME}" -n argo -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
    JOB_FAILED=$(kubectl get job "trigger-cert-${CLUSTER_NAME}" -n argo -o jsonpath='{.status.failed}' 2>/dev/null || echo "0")
    JOB_ACTIVE=$(kubectl get job "trigger-cert-${CLUSTER_NAME}" -n argo -o jsonpath='{.status.active}' 2>/dev/null || echo "0")

    if [ "$JOB_SUCCEEDED" -gt 0 ]; then
        print_success "Job completed successfully (succeeded: $JOB_SUCCEEDED)"
        PASSED=$((PASSED+1))
    elif [ "$JOB_ACTIVE" -gt 0 ]; then
        print_warning "Job is still running (active pods: $JOB_ACTIVE)"
        WARNINGS=$((WARNINGS+1))
    elif [ "$JOB_FAILED" -gt 0 ]; then
        print_error "Job failed (failed: $JOB_FAILED)"
        FAILED=$((FAILED+1))

        # Show pod logs if failed
        print_info "Fetching logs from failed job..."
        kubectl logs -n argo job/trigger-cert-${CLUSTER_NAME} --tail=50
    else
        print_warning "Job status unclear"
        WARNINGS=$((WARNINGS+1))
    fi
else
    print_error "Trigger Job 'trigger-cert-${CLUSTER_NAME}' not found"
    FAILED=$((FAILED+1))
fi

# =====================================
# 4. Check Workflow Instances
# =====================================
print_header "4. Workflow Execution Instances Check"

WORKFLOWS=$(kubectl get workflow -n argo -l "kro.run/cluster=${CLUSTER_NAME}" --no-headers 2>/dev/null | wc -l)

if [ "$WORKFLOWS" -gt 0 ]; then
    print_success "Found $WORKFLOWS workflow instance(s)"
    PASSED=$((PASSED+1))

    echo ""
    print_info "Workflow instances:"
    kubectl get workflow -n argo -l "kro.run/cluster=${CLUSTER_NAME}" -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,STARTED:.status.startedAt,FINISHED:.status.finishedAt,DURATION:.status.estimatedDuration

    # Get the most recent workflow
    LATEST_WORKFLOW=$(kubectl get workflow -n argo -l "kro.run/cluster=${CLUSTER_NAME}" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)

    if [ -n "$LATEST_WORKFLOW" ]; then
        echo ""
        print_info "Latest workflow: $LATEST_WORKFLOW"

        WORKFLOW_PHASE=$(kubectl get workflow "$LATEST_WORKFLOW" -n argo -o jsonpath='{.status.phase}')
        WORKFLOW_MESSAGE=$(kubectl get workflow "$LATEST_WORKFLOW" -n argo -o jsonpath='{.status.message}' 2>/dev/null || echo "")

        case "$WORKFLOW_PHASE" in
            Succeeded)
                print_success "Workflow status: $WORKFLOW_PHASE"
                PASSED=$((PASSED+1))
                ;;
            Failed|Error)
                print_error "Workflow status: $WORKFLOW_PHASE"
                FAILED=$((FAILED+1))
                if [ -n "$WORKFLOW_MESSAGE" ]; then
                    print_error "Message: $WORKFLOW_MESSAGE"
                fi
                ;;
            Running|Pending)
                print_warning "Workflow status: $WORKFLOW_PHASE"
                WARNINGS=$((WARNINGS+1))
                ;;
            *)
                print_warning "Workflow status: $WORKFLOW_PHASE"
                WARNINGS=$((WARNINGS+1))
                ;;
        esac
    fi
else
    print_error "No workflow instances found for cluster: $CLUSTER_NAME"
    FAILED=$((FAILED+1))
fi

# =====================================
# 5. Check Workflow Nodes/Tasks
# =====================================
if [ -n "${LATEST_WORKFLOW:-}" ]; then
    print_header "5. Workflow Tasks Status"

    if $JQ_AVAILABLE; then
        print_info "Analyzing workflow tasks..."
        NODES_JSON=$(kubectl get workflow "$LATEST_WORKFLOW" -n argo -o jsonpath='{.status.nodes}' 2>/dev/null)

        if [ -n "$NODES_JSON" ]; then
            echo "$NODES_JSON" | jq -r 'to_entries[] | "\(.value.displayName): \(.value.phase)"' | while read -r line; do
                TASK_NAME=$(echo "$line" | cut -d: -f1)
                TASK_PHASE=$(echo "$line" | cut -d: -f2 | xargs)

                case "$TASK_PHASE" in
                    Succeeded)
                        print_success "$TASK_NAME: $TASK_PHASE"
                        ;;
                    Failed|Error)
                        print_error "$TASK_NAME: $TASK_PHASE"
                        ;;
                    Running|Pending)
                        print_warning "$TASK_NAME: $TASK_PHASE"
                        ;;
                    *)
                        print_info "$TASK_NAME: $TASK_PHASE"
                        ;;
                esac
            done
        else
            print_warning "No task information available yet"
            WARNINGS=$((WARNINGS+1))
        fi
    else
        print_warning "jq not available - install jq for detailed task analysis"
        WARNINGS=$((WARNINGS+1))

        # Basic status without jq
        kubectl get workflow "$LATEST_WORKFLOW" -n argo -o jsonpath='{range .status.nodes.*}{.displayName}{": "}{.phase}{"\n"}{end}' 2>/dev/null || print_warning "Unable to fetch task status"
    fi
fi

# =====================================
# 6. Check Workflow Logs
# =====================================
if [ -n "${LATEST_WORKFLOW:-}" ]; then
    print_header "6. Recent Workflow Logs (Last 20 Lines)"

    print_info "Fetching logs for workflow: $LATEST_WORKFLOW"
    kubectl logs -n argo -l "workflows.argoproj.io/workflow=${LATEST_WORKFLOW}" --tail=20 2>/dev/null || print_warning "No logs available yet"
fi

# =====================================
# 7. Check Certification Report Artifact
# =====================================
if [ -n "${LATEST_WORKFLOW:-}" ] && [ "$WORKFLOW_PHASE" == "Succeeded" ]; then
    print_header "7. Certification Report Check"

    if $JQ_AVAILABLE; then
        ARTIFACTS=$(kubectl get workflow "$LATEST_WORKFLOW" -n argo -o json 2>/dev/null | jq -r '.status.nodes[] | select(.outputs.artifacts != null) | .outputs.artifacts[] | select(.name == "certification-report") | .name' 2>/dev/null || echo "")

        if [ -n "$ARTIFACTS" ]; then
            print_success "Certification report artifact found"
            PASSED=$((PASSED+1))

            # Try to display report content
            print_info "Report details would be stored in Argo artifact repository"
        else
            print_warning "Certification report artifact not found"
            WARNINGS=$((WARNINGS+1))
        fi
    else
        print_warning "jq not available - cannot check artifacts"
        WARNINGS=$((WARNINGS+1))
    fi
fi

# =====================================
# 8. Check UK8SClusterPublic Instance
# =====================================
print_header "8. UK8SClusterPublic Instance Status"

# Try to find the instance
INSTANCE_NAME=""
INSTANCE_NAMESPACE=""

# Search for instance with matching cluster name
while IFS= read -r line; do
    INST_NAME=$(echo "$line" | awk '{print $1}')
    INST_NS=$(echo "$line" | awk '{print $2}')
    INST_CLUSTER=$(echo "$line" | awk '{print $3}')

    if [ "$INST_CLUSTER" == "$CLUSTER_NAME" ]; then
        INSTANCE_NAME="$INST_NAME"
        INSTANCE_NAMESPACE="$INST_NS"
        break
    fi
done < <(kubectl get uk8sclusterpublic -A -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,CLUSTER:.spec.clusterName --no-headers 2>/dev/null)

if [ -n "$INSTANCE_NAME" ] && [ -n "$INSTANCE_NAMESPACE" ]; then
    print_success "UK8SClusterPublic instance found: $INSTANCE_NAME (namespace: $INSTANCE_NAMESPACE)"
    PASSED=$((PASSED+1))

    INSTANCE_STATE=$(kubectl get uk8sclusterpublic "$INSTANCE_NAME" -n "$INSTANCE_NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "UNKNOWN")
    INSTANCE_READY=$(kubectl get uk8sclusterpublic "$INSTANCE_NAME" -n "$INSTANCE_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

    print_info "State: $INSTANCE_STATE"
    print_info "Ready: $INSTANCE_READY"

    if [ "$INSTANCE_STATE" == "ACTIVE" ] && [ "$INSTANCE_READY" == "True" ]; then
        print_success "Instance is ACTIVE and Ready"
        PASSED=$((PASSED+1))
    else
        print_warning "Instance not fully ready (State: $INSTANCE_STATE, Ready: $INSTANCE_READY)"
        WARNINGS=$((WARNINGS+1))
    fi
else
    print_error "UK8SClusterPublic instance not found for cluster: $CLUSTER_NAME"
    FAILED=$((FAILED+1))
fi

# =====================================
# Final Summary
# =====================================
print_header "FINAL SUMMARY"

echo ""
print_info "Cluster: $CLUSTER_NAME"
print_success "Passed checks: $PASSED"
print_warning "Warnings: $WARNINGS"
print_error "Failed checks: $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    print_success "✅ All critical checks passed!"

    if [ $WARNINGS -gt 0 ]; then
        print_warning "⚠️  There are some warnings to review"
    fi

    exit 0
else
    print_error "❌ Some checks failed - review the output above"

    echo ""
    print_info "Troubleshooting tips:"
    echo "  1. Check KRO controller logs: kubectl logs -n kro-system -l app=kro-controller"
    echo "  2. Check Argo workflow controller logs: kubectl logs -n argo -l app=workflow-controller"
    echo "  3. Verify RBAC permissions: kubectl get clusterrolebinding | grep argo"
    echo "  4. Check UK8SClusterPublic status: kubectl describe uk8sclusterpublic $INSTANCE_NAME -n $INSTANCE_NAMESPACE"

    exit 1
fi
