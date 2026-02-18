  1. You submit a Workflow with the right parameters (query, namespace, pod, etc.)                                                                                                                                         
  2. Workflow calls KAgent controller at http://kagent-controller.kagent.svc.cluster.local:8083                                                                                                                            
  3. KAgent picks the agent (sre-triage-agent or sre-remediation-agent) based on remediate param
  4. Agent uses its model (qwen3-14b via KubeAI) + its k8s tools to investigate the cluster                                                                                                                                
  5. Results flow back → GitLab issue → Mattermost notification                       

  The bridge template I just created is only needed later when you want AlertManager to trigger it automatically (because AlertManager sends a raw JSON blob that needs parsing into the structured params).

  For testing right now, you can skip the bridge entirely and just submit directly:

  argo submit -n argo --from workflowtemplate/kagent-sre-workflow \
    -p query="Investigate CrashLoopBackOff for test-crashloop pod in default namespace" \
    -p event_type="KubePodCrashLooping" \
    -p namespace="default" \
    -p resource_kind="Pod" \
    -p resource_name="test-crashloop" \
    -p severity="medium" \
    -p remediate="false"