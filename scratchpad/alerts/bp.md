BigPanda was built for a different architectural era. It's a centralised correlation engine designed around the traditional L1/L2/L3 escalation model, where humans receive alerts and decide what to do.

That doesn't fit with where we're heading. Our model is GitOps-first, Kubernetes-native, and self-healing — detection and remediation happening in the same control loop through operators, Argo, and policy engines like Kyverno. BigPanda sits outside that loop entirely. It can observe, but it can't act.

Ignoring the alerts it generates is the symptom. The tool being not fit for purpose is the cause.

Time to start looking at alternatives that align with the platform we're actually building.