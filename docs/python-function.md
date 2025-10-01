Create your first containerized functions on Azure Container Apps
05/22/2025
Choose a programming language
In this article, you create a function app running in a Linux container and deploy it to an Azure Container Apps environment from a container registry. By deploying to Container Apps, you're able to integrate your function apps into cloud-native microservices. For more information, see Azure Container Apps hosting of Azure Functions.

 Important

A new hosting method for running Azure Functions directly in Azure Container Apps is now available. See Native Azure Functions Support in Azure Container Apps. This integration allows you to use the full features and capabilities of Azure Container Apps. You also benefit from the functions programming model and simplicity of autoscaling provided by Azure Functions.

We recommend this approach for most new workloads. For more information, see Azure Functions on Azure Container Apps.

This article shows you how to create functions running in a Linux container and deploy the container to a Container Apps environment.

Completing this quickstart incurs a small cost of a few USD cents or less in your Azure account, which you can minimize by cleaning-up resources when you're done.

Choose your development language
First, you use Azure Functions tools to create your project code as a function app in a Docker container using a language-specific Linux base image. Make sure to select your language of choice at the top of the article.

Core Tools automatically generates a Dockerfile for your project that uses the most up-to-date version of the correct base image for your functions language. You should regularly update your container from the latest base image and redeploy from the updated version of your container. For more information, see Creating containerized function apps.

Prerequisites
Before you begin, you must have the following requirements in place:

Install Azure Functions Core Tools version 4.x.
Install a version of Python that is supported by Azure Functions.
Azure CLI version 2.4 or a later version.
If you don't have an Azure subscription, create an Azure free account before you begin.

To publish the containerized function app image you create to a container registry, you need a Docker ID and Docker running on your local computer. If you don't have a Docker ID, you can create a Docker account.

Azure Container Registry
Docker Hub
You should be all set.

Create and activate a virtual environment
In a suitable folder, run the following commands to create and activate a virtual environment named .venv. Make sure to use one of the Python versions supported by Azure Functions.

bash
PowerShell
Cmd
Bash

Copy
python -m venv .venv
Bash

Copy
source .venv/bin/activate
If Python didn't install the venv package on your Linux distribution, run the following command:

Bash

Copy
sudo apt-get install python3-venv
You run all subsequent commands in this activated virtual environment.

Create and test the local functions project
In a terminal or command prompt, run the following command for your chosen language to create a function app project in the current folder:

Console

Copy
func init --worker-runtime python --docker
The --docker option generates a Dockerfile for the project, which defines a suitable container for use with Azure Functions and the selected runtime.

Use the following command to add a function to your project, where the --name argument is the unique name of your function and the --template argument specifies the function's trigger. func new creates a subfolder matching the function name that contains a configuration file named function.json.

Console

Copy
func new --name HttpExample --template "HTTP trigger"
To test the function locally, start the local Azure Functions runtime host in the root of the project folder.

Console

Copy
func start  
After you see the HttpExample endpoint written to the output, navigate to http://localhost:7071/api/HttpExample?name=Functions. The browser must display a "hello" message that echoes back Functions, the value supplied to the name query parameter.

Press Ctrl+C (Command+C on macOS) to stop the host.

Build the container image and verify locally
(Optional) Examine the Dockerfile in the root of the project folder. The Dockerfile describes the required environment to run the function app on Linux. The complete list of supported base images for Azure Functions can be found in the Azure Functions base image page.

In the root project folder, run the docker build command, provide a name as azurefunctionsimage, and tag as v1.0.0. Replace <DOCKER_ID> with your Docker Hub account ID. This command builds the Docker image for the container.

Console

Copy
docker build --tag <DOCKER_ID>/azurefunctionsimage:v1.0.0 .
When the command completes, you can run the new container locally.

To verify the build, run the image in a local container using the docker run command, replace <DOCKER_ID> again with your Docker Hub account ID, and add the ports argument as -p 8080:80:

Console

Copy
docker run -p 8080:80 -it <DOCKER_ID>/azurefunctionsimage:v1.0.0
After the image starts in the local container, browse to http://localhost:8080/api/HttpExample?name=Functions, which must display the same "hello" message as before. Because the HTTP triggered function you created uses anonymous authorization, you can call the function running in the container without having to obtain an access key. For more information, see authorization keys.

After verifying the function app in the container, press Ctrl+C (Command+C on macOS) to stop execution.

Publish the container image to a registry
To make your container image available for deployment to a hosting environment, you must push it to a container registry. As a security best practice, you should use an Azure Container Registry instance and enforce managed identity-based connections. Docker Hub requires you to authenticate using shared secrets, which make your deployments more vulnerable.

Azure Container Registry
Docker Hub
Docker Hub is a container registry that hosts images and provides image and container services.

If you haven't already signed in to Docker, do so with the docker login command, replacing <docker_id> with your Docker Hub account ID. This command prompts you for your username and password. A "sign in Succeeded" message confirms that you're signed in.

Console

Copy
docker login
After you've signed in, push the image to Docker Hub by using the docker push command, again replace the <docker_id> with your Docker Hub account ID.

Console

Copy
docker push <DOCKER_ID>/azurefunctionsimage:v1.0.0
Depending on your network speed, pushing the image for the first time might take a few minutes. Subsequent changes are pushed faster.

Create supporting Azure resources for your function
Before you can deploy your container to Azure, you need to create three resources:

A resource group, which is a logical container for related resources.
A Storage account, which is used to maintain state and other information about your functions.
An Azure Container Apps environment with a Log Analytics workspace.
A user-assigned managed identity, which enables your function app to securely connect to Azure resources without using shared secrets. Connections to both the Azure Storage account and to the Azure Container Registry instance are instead made using Microsoft Entra authentication with the identity, which is recommended for this scenario.
 Note

Docker Hub doesn't support managed identities.

Use these commands to create your required Azure resources:

If necessary, sign in to Azure:

The az login command signs you into your Azure account. Use az account set when you have more than one subscription associated with your account.

Run the following command to update the Azure CLI to the latest version:

Azure CLI

Copy
az upgrade
If your version of Azure CLI isn't the latest version, an installation begins. The manner of upgrade depends on your operating system. You can proceed after the upgrade is complete.

Run the following commands that upgrade the Azure Container Apps extension and register namespaces required by Container Apps:

Azure CLI

Copy
az extension add --name containerapp --upgrade -y
az provider register --namespace Microsoft.Web 
az provider register --namespace Microsoft.App 
az provider register --namespace Microsoft.OperationalInsights 
Create a resource group named AzureFunctionsContainers-rg.

Azure CLI

Copy
az group create --name AzureFunctionsContainers-rg --location eastus
This az group create command creates a resource group in the East US region. If you instead want to use a region near you, using an available region code returned from the az account list-locations command. You must modify subsequent commands to use your custom region instead of eastus.

Create Azure Container App environment with workload profiles enabled.

Azure CLI

Copy
az containerapp env create --name MyContainerappEnvironment --enable-workload-profiles --resource-group AzureFunctionsContainers-rg --location eastus
This command can take a few minutes to complete.

Create a general-purpose storage account in your resource group and region, without shared key access.

Azure CLI

Copy
az storage account create --name <STORAGE_NAME> --location eastus --resource-group AzureFunctionsContainers-rg --sku Standard_LRS --allow-blob-public-access false --allow-shared-key-access false
The az storage account create command creates the storage account that can only be accessed by using Microsoft Entra-authenticated identities that have been granted permissions to specific resources.

In the previous example, replace <STORAGE_NAME> with a name that is appropriate to you and unique in Azure Storage. Storage names must contain 3 to 24 characters numbers and lowercase letters only. Standard_LRS specifies a general-purpose account supported by Functions.

Create a managed identity and use the returned principalId to grant it both access to your storage account and pull permissions in your registry instance.

Azure CLI

Copy
principalId=$(az identity create --name <USER_IDENTITY_NAME> --resource-group AzureFunctionsContainers-rg --location eastus --query principalId -o tsv) 
acrId=$(az acr show --name <REGISTRY_NAME> --query id --output tsv)
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role acrpull --scope $acrId
storageId=$(az storage account show --resource-group AzureFunctionsContainers-rg --name <STORAGE_NAME> --query 'id' -o tsv)
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role "Storage Blob Data Owner" --scope $storageId
The az identity create command creates a user-assigned managed identity and the az role assignment create commands adds your identity to the required roles. Replace <REGISTRY_NAME>, <USER_IDENTITY_NAME>, and <STORAGE_NAME> with the name your existing container registry, the name for your managed identity, and the storage account name, respectively. The managed identity can now be used by an app to access both the storage account and Azure Container Registry without using shared secrets.

Create and configure a function app on Azure with the image
A function app on Azure manages the execution of your functions in your Azure Container Apps environment. In this section, you use the Azure resources from the previous section to create a function app from an image in a container registry in a Container Apps environment. You also configure the new environment with a connection string to the required Azure Storage account.

Use the az functionapp create command to create a function app in the new managed environment backed by Azure Container Apps. In az functionapp create, the --environment parameter specifies the Container Apps environment.

Azure Container Registry
Docker Hub
First you must get fully qualified ID value of your user-assigned managed identity, and then use the az functionapp create command to create a function app using the default image and with this identity assigned to it.

Azure CLI

Copy
az functionapp create --name <APP_NAME> --storage-account <STORAGE_NAME> --environment MyContainerappEnvironment --workload-profile-name "Consumption" --resource-group AzureFunctionsContainers-rg --functions-version 4 --assign-identity --image <DOCKER_ID>/azurefunctionsimage:v1.0.0  
In the az functionapp create command, the --environment parameter specifies the Container Apps environment and the --image parameter specifies the image to use for the function app. In this example, replace <STORAGE_NAME> with the name you used in the previous section for the storage account. Also, replace <APP_NAME> with a globally unique name appropriate to you and <DOCKER_ID> with your public Docker Hub account ID.

If you're using a private registry, you need to include the fully qualified domain name of your registry instead of just the Docker ID for <DOCKER_ID>, along with the --registry-username and --registry-password credential required to access the registry.

Specifying --workload-profile-name "Consumption" creates your app in an environment using the default Consumption workload profile, which costs the same as running in a Container Apps Consumption plan. When you first create the function app, it pulls the initial image from your registry.

Update application settings
To enable the Functions host to connect to the default storage account using shared secrets, you must replace the AzureWebJobsStorage connection string setting with an equivalent setting that uses the user-assigned managed identity to connect to the storage account.

Remove the existing AzureWebJobsStorage connection string setting:

Azure CLI

Copy
az functionapp config appsettings delete --name <APP_NAME> --resource-group AzureFunctionsContainers-rg --setting-names AzureWebJobsStorage 
The az functionapp config appsettings delete command removes this setting from your app. Replace <APP_NAME> with the name of your function app.

Add equivalent settings, with an AzureWebJobsStorage__ prefix, that define a user-assigned managed identity connection to the default storage account:

Azure CLI

Copy
clientId=$(az identity show --name <USER_IDENTITY_NAME> --resource-group AzureFunctionsContainers-rg --query 'clientId' -o tsv)
az functionapp config appsettings set --name <APP_NAME> --resource-group AzureFunctionsContainers-rg --settings AzureWebJobsStorage__accountName=<STORAGE_NAME> AzureWebJobsStorage__credential=managedidentity AzureWebJobsStorage__clientId=$clientId
In this example, replace <APP_NAME>, <USER_IDENTITY_NAME>, <STORAGE_NAME> with your function app name, the name of your identity, and the storage account name, respectively.

At this point, your functions are running in a Container Apps environment, with the required application settings already added. When needed, you can add other settings in your functions app in the standard way for Functions. For more information, see Use application settings.

 Tip

When you make subsequent changes to your function code, you need to rebuild the container, republish the image to the registry, and update the function app with the new image version. For more information, see Update an image in the registry

Verify your functions on Azure
With the image deployed to your function app in Azure, you can now invoke the function through HTTP requests.

Run the following az functionapp function show command to get the URL of your new function:

Azure CLI

Copy
az functionapp function show --resource-group AzureFunctionsContainers-rg --name <APP_NAME> --function-name HttpExample --query invokeUrlTemplate 
Replace <APP_NAME> with the name of your function app.

Use the URL you just obtained to call the HttpExample function endpoint, appending the query string ?name=Functions.
When you navigate to this URL, the browser must display similar output as when you ran the function locally.

The request URL should look something like this:

https://myacafunctionapp.kindtree-796af82b.eastus.azurecontainerapps.io/api/httpexample?name=functions

Clean up resources
If you want to continue working with Azure Function using the resources you created in this article, you can leave all those resources in place.

When you're done working with this function app deployment, delete the AzureFunctionsContainers-rg resource group to clean up all the resources in that group:

Azure CLI

Copy
az group delete --name AzureFunctionsContainers-rg
Next steps





