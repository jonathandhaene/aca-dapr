@description('Deployment location')
param location string = resourceGroup().location

@description('Container Apps environment name')
param containerAppsEnvironmentName string = 'aca-dapr-env'

@description('Log Analytics workspace name')
param logAnalyticsWorkspaceName string = 'law-aca-dapr'

@description('Azure Container Registry name (without domain)')
param acrName string

@description('Resource group containing the ACR')
param acrResourceGroup string = resourceGroup().name

@description('Level 1 dispatcher app name (Dapr publisher that routes tasks)')
param dispatcherAppName string = 'dispatcher'

@description('Level 0 producer job names (Job1 = orders feed, Job2 = signups feed)')
param level0Job1Name string = 'level0-job1'
param level0Job2Name string = 'level0-job2'

@description('Level 2 worker job names (one per routing target)')
param level2Job1Name string = 'level2-job1'
param level2Job2Name string = 'level2-job2'
param level2Job3Name string = 'level2-job3'

@description('Service Bus namespace name')
param serviceBusNamespaceName string = 'sb-aca-dapr'

@description('One Service Bus topic per Level 2 worker job')
param tasksTopicJob1 string = 'tasks-job1'
param tasksTopicJob2 string = 'tasks-job2'
param tasksTopicJob3 string = 'tasks-job3'

@description('Subscription name each Level 2 job consumes (same name on every topic)')
param tasksSubscriptionName string = 'workers'

@description('Dispatcher routing knob: orders at or above this amount go to the priority job')
param highValueThreshold int = 100

@description('Dispatcher routing knob: how many seconds to delay signup (welcome) tasks')
param signupDelaySeconds int = 30

@description('Maximum parallel executions of each Level 2 job')
param level2MaxExecutions int = 100

@description('Parallelism (replicas per execution) of each Level 2 job')
param level2Parallelism int = 10

@description('Default Service Bus message TTL in ISO8601 duration format (example: P14D)')
param serviceBusDefaultMessageTimeToLive string = 'P14D'

@description('Container image for the Level 1 dispatcher app')
param dispatcherImage string

@description('Container image shared by both Level 0 producer jobs')
param level0Image string

@description('Container image shared by all three Level 2 worker jobs')
param level2Image string

var acrPullRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

// All task topics, used to create the Service Bus topics + subscriptions.
var taskTopics = [
  tasksTopicJob1
  tasksTopicJob2
  tasksTopicJob3
]

// The two Level 0 producer jobs. They share one image and differ only by the
// file they read and the task `kind` they emit.
var level0Jobs = [
  {
    name: level0Job1Name
    inputFile: '/app/data/orders.txt'
    kind: 'order'
  }
  {
    name: level0Job2Name
    inputFile: '/app/data/signups.txt'
    kind: 'signup'
  }
]

// The three Level 2 worker jobs. They share one image and differ only by the
// topic they consume and the worker label they log under.
var level2Jobs = [
  {
    name: level2Job1Name
    topic: tasksTopicJob1
    worker: 'job1-priority'
  }
  {
    name: level2Job2Name
    topic: tasksTopicJob2
    worker: 'job2-standard'
  }
  {
    name: level2Job3Name
    topic: tasksTopicJob3
    worker: 'job3-welcome'
  }
]

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
  scope: resourceGroup(acrResourceGroup)
}

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource managedEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerAppsEnvironmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: listKeys(law.id, law.apiVersion).primarySharedKey
      }
    }
  }
}

resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2023-01-01-preview' = {
  name: serviceBusNamespaceName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    zoneRedundant: false
  }
}

// One topic per Level 2 job. The dispatcher publishes to whichever topic its
// routing rules choose, which is how it selects which job runs.
resource tasksTopicResources 'Microsoft.ServiceBus/namespaces/topics@2023-01-01-preview' = [for topic in taskTopics: {
  parent: serviceBusNamespace
  name: topic
  properties: {
    defaultMessageTimeToLive: serviceBusDefaultMessageTimeToLive
    maxSizeInMegabytes: 1024
  }
}]

// One subscription per topic. KEDA watches these to scale the Level 2 jobs.
resource tasksSubscriptionResources 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2023-01-01-preview' = [for (topic, i) in taskTopics: {
  parent: tasksTopicResources[i]
  name: tasksSubscriptionName
  properties: {
    defaultMessageTimeToLive: serviceBusDefaultMessageTimeToLive
    maxDeliveryCount: 10
    deadLetteringOnMessageExpiration: true
  }
}]

resource serviceBusAuthRule 'Microsoft.ServiceBus/namespaces/AuthorizationRules@2023-01-01-preview' = {
  parent: serviceBusNamespace
  name: 'dapr-apps'
  properties: {
    rights: [
      'Listen'
      'Send'
    ]
  }
}

// Dapr pub/sub component. The dispatcher uses this to publish to any of the
// three topics. Entity management is disabled because we pre-create the topics
// and subscriptions above (the auth rule only grants Listen + Send).
resource pubsubComponent 'Microsoft.App/managedEnvironments/daprComponents@2024-03-01' = {
  name: 'pubsub'
  parent: managedEnv
  properties: {
    componentType: 'pubsub.azure.servicebus'
    version: 'v1'
    ignoreErrors: false
    initTimeout: '5s'
    metadata: [
      {
        name: 'namespaceName'
        value: serviceBusNamespaceName
      }
      {
        name: 'connectionString'
        secretRef: 'servicebus-connection-string'
      }
      {
        name: 'disableEntityManagement'
        value: 'true'
      }
    ]
    secrets: [
      {
        name: 'servicebus-connection-string'
        value: listKeys(serviceBusAuthRule.id, serviceBusAuthRule.apiVersion).primaryConnectionString
      }
    ]
    scopes: [
      dispatcherAppName
    ]
  }
}

resource dispatcherApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: dispatcherAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: managedEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: 3000
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: 'system'
        }
      ]
      dapr: {
        enabled: true
        appId: dispatcherAppName
        appPort: 3000
      }
    }
    template: {
      containers: [
        {
          name: 'dispatcher'
          image: dispatcherImage
          env: [
            {
              name: 'NODE_ENV'
              value: 'production'
            }
            {
              name: 'PUBSUB_NAME'
              value: 'pubsub'
            }
            {
              name: 'TOPIC_JOB1'
              value: tasksTopicJob1
            }
            {
              name: 'TOPIC_JOB2'
              value: tasksTopicJob2
            }
            {
              name: 'TOPIC_JOB3'
              value: tasksTopicJob3
            }
            {
              name: 'HIGH_VALUE_THRESHOLD'
              value: string(highValueThreshold)
            }
            {
              name: 'SIGNUP_DELAY_SECONDS'
              value: string(signupDelaySeconds)
            }
          ]
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/healthz'
                port: 3000
              }
              initialDelaySeconds: 10
              periodSeconds: 10
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/healthz'
                port: 3000
              }
              initialDelaySeconds: 5
              periodSeconds: 5
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 5
      }
    }
  }
  dependsOn: [
    pubsubComponent
  ]
}

// Level 0 producer jobs (Job1 = orders, Job2 = signups). Manual trigger: you
// start them on demand; each reads its file and POSTs tasks to the dispatcher.
resource level0JobResources 'Microsoft.App/jobs@2024-03-01' = [for job in level0Jobs: {
  name: job.name
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    environmentId: managedEnv.id
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 1800
      replicaRetryLimit: 1
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: 'system'
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'level0'
          image: level0Image
          env: [
            {
              name: 'DISPATCHER_URL'
              value: 'https://${dispatcherApp.properties.configuration.ingress.fqdn}/dispatch'
            }
            {
              name: 'INPUT_FILE'
              value: job.inputFile
            }
            {
              name: 'TASK_KIND'
              value: job.kind
            }
          ]
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
        }
      ]
    }
  }
}]

// Level 2 worker jobs (one per topic). Event trigger: KEDA scales each from
// zero based on the depth of its own subscription — no CRON anywhere.
resource level2JobResources 'Microsoft.App/jobs@2024-03-01' = [for (job, i) in level2Jobs: {
  name: job.name
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    environmentId: managedEnv.id
    configuration: {
      triggerType: 'Event'
      replicaTimeout: 1800
      replicaRetryLimit: 1
      secrets: [
        {
          name: 'servicebus-connection-string'
          value: listKeys(serviceBusAuthRule.id, serviceBusAuthRule.apiVersion).primaryConnectionString
        }
      ]
      eventTriggerConfig: {
        parallelism: level2Parallelism
        replicaCompletionCount: 1
        scale: {
          minExecutions: 0
          maxExecutions: level2MaxExecutions
          pollingInterval: 30
          rules: [
            {
              name: 'servicebus-tasks'
              type: 'azure-servicebus'
              metadata: {
                topicName: job.topic
                subscriptionName: tasksSubscriptionName
                messageCount: '1'
              }
              auth: [
                {
                  secretRef: 'servicebus-connection-string'
                  triggerParameter: 'connection'
                }
              ]
            }
          ]
        }
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: 'system'
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'level2'
          image: level2Image
          env: [
            {
              name: 'SERVICEBUS_CONNECTION'
              secretRef: 'servicebus-connection-string'
            }
            {
              name: 'TASKS_TOPIC'
              value: job.topic
            }
            {
              name: 'TASKS_SUBSCRIPTION'
              value: tasksSubscriptionName
            }
            {
              name: 'WORKER_NAME'
              value: job.worker
            }
          ]
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
        }
      ]
    }
  }
  dependsOn: [
    tasksSubscriptionResources
  ]
}]

// AcrPull for the dispatcher app.
resource dispatcherAcrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, dispatcherApp.name, 'AcrPull')
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: dispatcherApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// AcrPull for each Level 0 producer job.
resource level0AcrPullRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (job, i) in level0Jobs: {
  name: guid(acr.id, job.name, 'AcrPull')
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: level0JobResources[i].identity.principalId
    principalType: 'ServicePrincipal'
  }
}]

// AcrPull for each Level 2 worker job.
resource level2AcrPullRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (job, i) in level2Jobs: {
  name: guid(acr.id, job.name, 'AcrPull')
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: level2JobResources[i].identity.principalId
    principalType: 'ServicePrincipal'
  }
}]

output dispatcherFqdn string = dispatcherApp.properties.configuration.ingress.fqdn
output level0JobNames array = [for job in level0Jobs: job.name]
output level2JobNames array = [for job in level2Jobs: job.name]
