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

@description('Checkout app name')
param checkoutAppName string = 'checkout-service'

@description('Inventory app name')
param inventoryAppName string = 'inventory-service'

@description('Service Bus namespace name')
param serviceBusNamespaceName string = 'sb-aca-dapr'

@description('Service Bus topic used for orders events')
param serviceBusTopicName string = 'orders'

@description('Service Bus subscription consumed by inventory service')
param serviceBusSubscriptionName string = 'inventory'

@description('Default Service Bus message TTL in ISO8601 duration format (example: P14D)')
param serviceBusDefaultMessageTimeToLive string = 'P14D'

@description('Storage account name for Dapr statestore (3-24 lowercase letters and numbers)')
param storageAccountName string

@description('Days to retain state blobs before automatic lifecycle deletion')
param stateBlobRetentionDays int = 30

@description('Container image for checkout service')
param checkoutImage string

@description('Container image for inventory service')
param inventoryImage string

var acrPullRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

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

resource serviceBusTopic 'Microsoft.ServiceBus/namespaces/topics@2023-01-01-preview' = {
  parent: serviceBusNamespace
  name: serviceBusTopicName
  properties: {
    defaultMessageTimeToLive: serviceBusDefaultMessageTimeToLive
    maxSizeInMegabytes: 1024
  }
}

resource serviceBusSubscription 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2023-01-01-preview' = {
  parent: serviceBusTopic
  name: serviceBusSubscriptionName
  properties: {
    defaultMessageTimeToLive: serviceBusDefaultMessageTimeToLive
    maxDeliveryCount: 10
    deadLetteringOnMessageExpiration: true
  }
}

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

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource stateContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'dapr-state'
  properties: {
    publicAccess: 'None'
  }
}

resource storageLifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          enabled: true
          name: 'expire-dapr-state'
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                '${stateContainer.name}/'
              ]
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: stateBlobRetentionDays
                }
              }
            }
          }
        }
      ]
    }
  }
}

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
    ]
    secrets: [
      {
        name: 'servicebus-connection-string'
        value: listKeys(serviceBusAuthRule.id, serviceBusAuthRule.apiVersion).primaryConnectionString
      }
    ]
    scopes: [
      checkoutAppName
      inventoryAppName
    ]
  }
}

resource stateStoreComponent 'Microsoft.App/managedEnvironments/daprComponents@2024-03-01' = {
  name: 'statestore'
  parent: managedEnv
  properties: {
    componentType: 'state.azure.blobstorage'
    version: 'v1'
    ignoreErrors: false
    initTimeout: '5s'
    metadata: [
      {
        name: 'accountName'
        value: storage.name
      }
      {
        name: 'accountKey'
        secretRef: 'storage-account-key'
      }
      {
        name: 'containerName'
        value: stateContainer.name
      }
    ]
    secrets: [
      {
        name: 'storage-account-key'
        value: listKeys(storage.id, storage.apiVersion).keys[0].value
      }
    ]
    scopes: [
      inventoryAppName
    ]
  }
}

resource checkoutApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: checkoutAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: managedEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
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
        appId: checkoutAppName
        appPort: 3000
      }
    }
    template: {
      containers: [
        {
          name: 'checkout'
          image: checkoutImage
          env: [
            {
              name: 'NODE_ENV'
              value: 'production'
            }
          ]
          resources: {
            cpu: 0.5
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

resource inventoryApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: inventoryAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: managedEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 3001
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: 'system'
        }
      ]
      dapr: {
        enabled: true
        appId: inventoryAppName
        appPort: 3001
      }
    }
    template: {
      containers: [
        {
          name: 'inventory'
          image: inventoryImage
          env: [
            {
              name: 'NODE_ENV'
              value: 'production'
            }
          ]
          resources: {
            cpu: 0.5
            memory: '1Gi'
          }
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/healthz'
                port: 3001
              }
              initialDelaySeconds: 10
              periodSeconds: 10
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/healthz'
                port: 3001
              }
              initialDelaySeconds: 5
              periodSeconds: 5
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 10
      }
    }
  }
  dependsOn: [
    pubsubComponent
    stateStoreComponent
  ]
}

resource checkoutAcrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, checkoutApp.name, 'AcrPull')
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: checkoutApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource inventoryAcrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, inventoryApp.name, 'AcrPull')
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: inventoryApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output checkoutFqdn string = checkoutApp.properties.configuration.ingress.fqdn
output inventoryFqdn string = inventoryApp.properties.configuration.ingress.fqdn
output serviceBusNamespaceFqdn string = '${serviceBusNamespaceName}.servicebus.windows.net'
output storageAccount string = storage.name
