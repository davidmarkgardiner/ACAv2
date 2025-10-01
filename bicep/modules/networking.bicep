// ============================================================================
// Networking Module - VNet and Subnet for Container Apps
// ============================================================================
// Creates Virtual Network and dedicated subnet for Container App Environment
// with proper address space allocation and NSG configuration.
// ============================================================================

@description('Name of the Virtual Network')
param vnetName string

@description('Location for resources')
param location string = resourceGroup().location

@description('Virtual Network address prefix')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Container Apps subnet name')
param containerAppsSubnetName string = 'aca-subnet'

@description('Container Apps subnet prefix (requires /23 or larger for environment)')
param containerAppsSubnetPrefix string = '10.0.0.0/23'

@description('Network Security Group name')
param nsgName string = '${containerAppsSubnetName}-nsg'

@description('Tags to apply to resources')
param tags object = {}

// ============================================================================
// Network Security Group
// ============================================================================

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowHTTPSInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowHTTPInbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ============================================================================
// Virtual Network
// ============================================================================

resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: containerAppsSubnetName
        properties: {
          addressPrefix: containerAppsSubnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Resource ID of the Virtual Network')
output vnetId string = vnet.id

@description('Name of the Virtual Network')
output vnetName string = vnet.name

@description('Resource ID of the Container Apps subnet')
output subnetId string = '${vnet.id}/subnets/${containerAppsSubnetName}'

@description('Container Apps subnet name')
output subnetName string = containerAppsSubnetName

@description('NSG Resource ID')
output nsgId string = nsg.id
