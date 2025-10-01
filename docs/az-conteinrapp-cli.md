az containerapp -h

Group
    az containerapp : Manage Azure Container Apps.

Subgroups:
    add-on                   [Preview] : Commands to manage add-ons available within the
                                         environment.
    arc                      [Preview] : Install prerequisites for Kubernetes cluster on
                                         Arc.
    auth                               : Manage containerapp authentication and authorization.
    compose                            : Commands to create Azure Container Apps from Compose
                                         specifications.
    connected-env            [Preview] : Commands to manage Container Apps Connected
                                         environments for use with Arc enabled Container Apps.
    connection                         : Commands to manage containerapp connections.
    dapr                               : Commands to manage Dapr. To manage Dapr components, see `az
                                         containerapp env dapr-component`.
    env                                : Commands to manage Container Apps environments.
    github-action                      : Commands to manage GitHub Actions.
    hostname                           : Commands to manage hostnames of a container app.
    identity                           : Commands to manage managed identities.
    ingress                            : Commands to manage ingress and traffic-splitting.
    java                               : Commands to manage Java workloads.
    job                                : Commands to manage Container Apps jobs.
    label-history            [Preview] : Show the history for one or more labels on the
                                         Container App.
    logs                               : Show container app logs.
    patch                    [Preview] : Patch Azure Container Apps. Patching is only
                                         available for the apps built using the source to cloud
                                         feature. See https://aka.ms/aca-local-source-to-cloud.
    registry                 [Preview] : Commands to manage container registry information.
    replica                            : Manage container app replicas.
    resiliency               [Preview] : Commands to manage resiliency policies for a
                                         container app.
    revision                           : Commands to manage revisions.
    secret                             : Commands to manage secrets.
    session                            : Commands to manage sessions.To learn more about individual
                                         commands under each subgroup run containerapp session
                                         [subgroup name] --help.
    sessionpool                        : Commands to manage session pools.
    ssl                                : Upload certificate to a managed environment, add hostname
                                         to an app in that environment, and bind the certificate to
                                         the hostname.

Commands:
    browse                             : Open a containerapp in the browser, if possible.
    create                             : Create a container app.
    debug                    [Preview] : Open an SSH-like interactive shell within a
                                         container app debug console.
    delete                             : Delete a container app.
    exec                               : Open an SSH-like interactive shell within a container app
                                         replica.
    list                               : List container apps.
    list-usages                        : List usages of subscription level quotas in specific
                                         region.
    show                               : Show details of a container app.
    show-custom-domain-verification-id : Show the verification id for binding app or environment
                                         custom domains.
    up                                 : Create or update a container app as well as any associated
                                         resources (ACR, resource group, container apps environment,
                                         GitHub Actions, etc.).
    update                             : Update a container app. In multiple revisions mode, create
                                         a new revision based on the latest revision.

To search AI knowledge base for examples, use: az find "az containerapp"