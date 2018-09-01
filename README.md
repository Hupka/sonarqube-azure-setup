# Serverless SonarQube setup on Azure & connection to VSTS  <!-- omit in toc -->

I was looking for a way to set up a low maintenance SonarQube instance to be integrated into my VSTS build pipelines projects. Additionally the setup should be robust & secure, so I could with a clear conscience use it my team at work.

Here is a list of constraints that I considered for the setup:

* I want a **serverless setup** to not care about a VM (patching, configuration, monitoring, etc.)
* I want to use **Docker**
* I want to use a **managed database** (SQL) to be not concerned about backups & availability
* I want to use a **key vault** to securely store the needed credentials
* I want to use our **private container registry** to store & pull the customized SonarQube Docker images

Considering this list of constraints I was searching the internet for a guide that might already come close to what I wanted to achieve. And indeed I ended up working through [Nathanael's guide](https://www.natmarchand.fr/sonarqube-azure-webapp-containers/). I copied over many of the steps he explained into my guide here, stripped of the Powershell bits and pieces and adapted his `entrypoint.sh` script for my Dockerfile.

I settled with the following technologies/products:

* **Azure Web Apps on Linux** as the serverless environment for hosting our web application
* **Azure SQL Database** as the managed database our web app connects to
* **Azure Key Vault** as the secret store
* **Azure Container Registry** to upload our Docker container images

I have uploaded this guide, the referenced shell scripts as well as the Dockerfile to a [GitHub repository](https://github.com/EddEdw/sonarqube-azure-setup).

#### Table of Contents  <!-- omit in toc -->
- [Prerequisites](#prerequisites)
- [Step 1: Gather data to set `env` variables](#step-1-gather-data-to-set-env-variables)
- [Step 2: Build our Docker image and push it to our private registry](#step-2-build-our-docker-image-and-push-it-to-our-private-registry)
- [Step 3: Create the managed SQL database](#step-3-create-the-managed-sql-database)
- [Step 4: Test if you have everything to connect to your database](#step-4-test-if-you-have-everything-to-connect-to-your-database)
- [Step 5: Setup Azure Web App with our SonarQube image](#step-5-setup-azure-web-app-with-our-sonarqube-image)
- [Step 6: Enable Azure AD authentication for your SonarQube instance](#step-6-enable-azure-ad-authentication-for-your-sonarqube-instance)
- [Final step: Connect SonarQube to VSTS](#final-step-connect-sonarqube-to-vsts)

## Prerequisites

There are a few things I assume the reader has configured on his machine and is generally familiar with. Furthermore I am using a Macbook - but since this guide mainly relies on Azure's CLI, 99% of it can be executed on either Windows or Linux without any rework.

1. Install [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest)
2. Create an [Azure Key Vault](https://docs.microsoft.com/en-us/azure/key-vault/quick-create-cli) instance
3. Create an [Azure Container Registry](https://docs.microsoft.com/en-us/azure/container-registry/container-registry-get-started-azure-cli)
4. Install `jq` using `brew install jq` to parse JSON in the command line ([jq manual](https://stedolan.github.io/jq/))
5. Log into your Azure subscription using `az login`

## Step 1: Gather data to set `env` variables

You want to make sure all secrets are stored in your Azure Key Vault. The SQL database login credentials have to be chosen by the user in advance of the database creation. The admin credentials for the Azure Container Registry are retrieved using `az acr credential show --name <acrName>` after the database was created.

```bash
export YOUR_KEY_VAULT="<your-key-vault>"
az keyvault secret set --vault-name $YOUR_KEY_VAULT --name 'sonarqube-sql-admin' --value '<VALUE>'
az keyvault secret set --vault-name $YOUR_KEY_VAULT --name 'sonarqube-sql-admin-password' --value '<VALUE>'
az keyvault secret set --vault-name $YOUR_KEY_VAULT --name 'container-registry-admin' --value '<VALUE>'
az keyvault secret set --vault-name $YOUR_KEY_VAULT --name 'container-registry-admin-password' --value '<VALUE>'
```

Here the set of variables used throughout this guide. Notice we retrieve Azure Keyvault secrets using the Azure CLI and not with a Service Principal. This would be more secure but you Azure user account is required to be permitted to work with Service Principal users.

```bash
# General
export PROJECT_PREFIX="<your-project-prefix>"
export RESOURCE_GROUP_NAME="$PROJECT_PREFIX-sonarqube-rg"
export LOCATION="westeurope"

# SQL database related
export SQL_ADMIN_USER=`az keyvault secret show -n sonarqube-sql-admin --vault-name $YOUR_KEY_VAULT | jq -r '.value'`
export SQL_ADMIN_PASSWORD=`az keyvault secret show -n sonarqube-sql-admin-password --vault-name $YOUR_KEY_VAULT | jq -r '.value'`
export SQL_SERVER_NAME="$PROJECT_PREFIX-sql-server"
export DATABASE_NAME="$PROJECT_PREFIX-sonar-sql-db"
export DATABASE_SKU="S0"

# Webapp related 
export APP_SERVICE_NAME="$PROJECT_PREFIX-sonarqube-app-service"
export APP_SERVICE_SKU="S1"

# Container image related
export CONTAINER_REGISTRY_NAME="<your-acr-name>"
export CONTAINER_REGISTRY_FQDN="$CONTAINER_REGISTRY_NAME.azurecr.io"
export REG_ADMIN_USER=`az keyvault secret show -n container-registry-admin --vault-name $YOUR_KEY_VAULT | jq -r '.value'`
export REG_ADMIN_PASSWORD=`az keyvault secret show -n container-registry-admin-password --vault-name $YOUR_KEY_VAULT | jq -r '.value'`
export WEBAPP_NAME="$PROJECT_PREFIX-sonarqube-webapp"
export CONTAINER_IMAGE_NAME="$PROJECT_PREFIX-sonar"

# Concatenated variable strings for better readability
export DB_CONNECTION_STRING="jdbc:sqlserver://$SQL_SERVER_NAME.database.windows.net:1433;database=$DATABASE_NAME;user=$SQL_ADMIN_USER@$SQL_SERVER_NAME;password=$SQL_ADMIN_PASSWORD;encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30;"
```

## Step 2: Build our Docker image and push it to our private registry

Nathanael explains in his [guide](https://www.natmarchand.fr/sonarqube-azure-webapp-containers/) that it is not immediately obvious to persist container data across reboots. We need to mount an App Service storage as a volume for our SonarQube container. Currently users have not much control over the mounting process and, therefore, the volume will be mounted by the App Service at the path `/home`. He writes:

> The downside is that, at build time in Docker, we cannot use this folder as its content is going to be discarded at mount. Additionally, we have to make Sonarqube use this directory to store all the state.

He goes on to write about how he proposes to configure SonarQube:

> The vanilla Sonarqube image use the folder /opt/sonarqube, one way to achieve what we want is by moving the content we need from /opt/sonarqube to /home/sonarqube and then make symbolic links to preserve the architecture. Unfortunately, the Sonarqube vanilla image also declares a volume on /opt/sonarqube/data, we won’t be able to move, replace, update this folder. All of this can be done by adding a thin layer to the Docker image that contains a shell script that does all the work.

```bash
# Checkout the repository containing the Dockerfile and the config script
git clone https://github.com/EddEdw/sonarqube-azure-setup.git && cd sonarqube-azure-setup

# Log into your Azure Container Registry  
az acr login --name $CONTAINER_REGISTRY_NAME

# Build the image and push to the registry
docker build -t $CONTAINER_IMAGE_NAME:latest .
docker tag $CONTAINER_IMAGE_NAME:latest "$CONTAINER_REGISTRY_FQDN/$CONTAINER_IMAGE_NAME:latest"
docker push "$CONTAINER_REGISTRY_FQDN/$CONTAINER_IMAGE_NAME:latest"
```

## Step 3: Create the managed SQL database

The setup of the SQL database is pretty straight forward. We start by creating a resource group where all resources specific to this guide are stored in and afterwards setup a SQL server + database with a small/cheap SKU. This can of course be easily & quickly adapted at a later stage through the portal or the CLI. We furthermore add a firewall rule to allow incoming requests from Azure resources only.

```bash
# Add resource group; tag appropriately :-)
az group create \
    --name $RESOURCE_GROUP_NAME \
    --location $LOCATION \
    --tag 'createdBy=<YOU>' 'createdFor=Resource group for SonarQube components'

# Create sql server and database
az sql server create \
    --name $SQL_SERVER_NAME \
    --resource-group $RESOURCE_GROUP_NAME \
    --location $LOCATION \
    --admin-user $SQL_ADMIN_USER \
    --admin-password $SQL_ADMIN_PASSWORD
az sql db create \
    --resource-group $RESOURCE_GROUP_NAME \
    --server $SQL_SERVER_NAME \
    --name $DATABASE_NAME \
    --service-objective $DATABASE_SKU \
    --collation "SQL_Latin1_General_CP1_CS_AS"

# Set SQL server's firewall rules to accept requests from Azure services only (this is going to be our Azure Webapp)
az sql server firewall-rule create \
    --resource-group $RESOURCE_GROUP_NAME \
    --server $SQL_SERVER_NAME -n "AllowAllWindowsAzureIps" \
    --start-ip-address 0.0.0.0 \
    --end-ip-address 0.0.0.0
```

## Step 4: Test if you have everything to connect to your database

This step is particularly for myself: I lost a couple of hours because I always went through the full guide deploying the instance to the hard-to-debug Azure Web App. Due to my unfamiliarity with Azure Web Apps it cost me hours to pinpoint down the issues I had. What in the end saved me, and should have been my go-to right away, was testing everything locally!

> Note: this locally tested call might compromise the SQL database. After testing this locally I had to delete the SQL database (not the server!) and re-create it with the command in Step 3.

To have a locally run Docker container connect to your Azure SQL database you have to extend the firewall rules to accept incoming requests from your current client ip address. Azure helps you here: navigate to **https://portal.azure.com** -> `<your-sql-server>` -> **"Firewalls and virtual networks"** and click the button at the top **"+ Add client IP"** and press **"save"** afterwards. After a few seconds your locally run Docker container can access your SQL server.

```bash
docker run \
    --name sonarqube \
    -p 9000:9000 \
    -p 9092:9092 \
    -e "SQLAZURECONNSTR_SONARQUBE_JDBC_URL=jdbc:sqlserver://$SQL_SERVER_NAME.database.windows.net:1433;database=$DATABASE_NAME;user=$SQL_ADMIN_USER@$SQL_SERVER_NAME;password=$SQL_ADMIN_PASSWORD;encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30;" \
    $CONTAINER_REGISTRY_FQDN/$CONTAINER_IMAGE_NAME:latest
```

This tests a couple of things:

1. Can you connect to your private Docker Registry?
2. Can you bind the SonarQube image to your managed SQL database?
3. ... and you get a feeling about how the logs for this setup look like - which helps later on. ;-)

## Step 5: Setup Azure Web App with our SonarQube image

Deploying the web app is a two-step process: first we create an App Service and connect it with our Web App and the second step is configuring the WebApp to run our container and feeding it with the correct environment variables.

```bash
# Create an Azure App Service Plan with Linux as Host OS
az appservice plan create \
    --resource-group $RESOURCE_GROUP_NAME \
    --name $APP_SERVICE_NAME \
    --sku $APP_SERVICE_SKU \
    --is-linux

# Create the WebApp hosting the Sonarqube container
az webapp create \
    --resource-group $RESOURCE_GROUP_NAME \
    --plan $APP_SERVICE_NAME \
    --name $WEBAPP_NAME \
    --deployment-container-image-name $CONTAINER_REGISTRY_FQDN/$CONTAINER_IMAGE_NAME
```

After the Web App is deployed we have to configure it correctly. The very special part here is the `connectionString` to the Azure SQL database. We can't just set it as a regular environment variable but have to consider some Web App logic for the `connectionString`'s name.

As stated in the [docs](https://docs.microsoft.com/en-us/azure/app-service/web-sites-configure#connection-strings), when the Web App hosts a .NET application `connectionStrings` are *injected*. If it is **not** a .NET app, all `connectionStrings` are added as environment variables prefixed with the connection type - in our case **SQL Database**, hence prefixed with `SQLAZURECONNSTR_`. Our Dockerfile already expects an environment variable with this prefix. For our Web App, we have to explicitly omit this prefix, since it gets added at startup.

```bash
# Configure the WebApp
az webapp config connection-string set \
    --resource-group $RESOURCE_GROUP_NAME \
    --name $WEBAPP_NAME -t SQLAzure \
    --settings SONARQUBE_JDBC_URL=$DB_CONNECTION_STRING
az webapp config set \
    --resource-group $RESOURCE_GROUP_NAME \
    --name $WEBAPP_NAME \
    --always-on true
az webapp log config \
    --resource-group $RESOURCE_GROUP_NAME \
    --name $WEBAPP_NAME \
    --docker-container-logging filesystem
az webapp config container set \
    --name $WEBAPP_NAME \
    --resource-group $RESOURCE_GROUP_NAME \
    --docker-custom-image-name $CONTAINER_REGISTRY_FQDN/$CONTAINER_IMAGE_NAME \
    --docker-registry-server-url https://$CONTAINER_REGISTRY_FQDN \
    --docker-registry-server-user $REG_ADMIN_USER \
    --docker-registry-server-password $REG_ADMIN_PASSWORD
```

The last command registers our container registry and authorizes the Web App for pulling images. At this point everything is set up and we need a little patience. I suggest you restart the Web App to be sure all environment variables are correctly picked up and wait for a few minutes.

```bash
# Restart app to ensure all environment variables are considered correctly; wait 5 minutes.
az webapp restart \
    --resource-group $RESOURCE_GROUP_NAME \
    --name $WEBAPP_NAME
```

If the SonarQube container does not spin up or you find out that SonarQube didn't connect to the SQL database but hosts an internal database instead, you should have a look at the logs:

```bash
# Download logs to current directory
az webapp log download \
    --resource-group $RESOURCE_GROUP_NAME \
    --name $WEBAPP_NAME
```

If everything went well you now have a running SonarQube instance in an Azure Web App connected to an managed Azure SQL database. Well done! You can now tweak the sizing parameters: more compute power for the Web App, more storage for the SQL database.

## Step 6: Enable Azure AD authentication for your SonarQube instance

We want to avoid doing access management ourselves in distributed places and we neither want to manage user identities by ourselves. SonarQube has a great community plugin that integrates Azure Active Directory as authentication provider. The plugin offers a very comprehensive [step by step guide to connect the plugin to Azure AD](https://github.com/SonarQubeCommunity/sonar-auth-aad#create-active-directory-application-under-your-azure-active-directory-tenant).


The only addition I have to make is that I could only get the plugin to work by adding 2 callback URLs to the AAD App registration. The two callback URLs only are only different in the strange "double slash". Initially it wasn't working and I debugged the SonarQube client's REST calls to AAD and found out about this. Maybe only I have the issue, but maybe it also saves you.

```bash
https://<$WEBAPP_NAME>.azurewebsites.net/oauth2/callback/aad
https://<$WEBAPP_NAME>.azurewebsites.net//oauth2/callback/aad
```

In the SonarQube AAD plugin config make sure you use `Unique` as value for `Login generation strategy`. You now control access to your application by adding Azure Users of your organization to your App Registration in AAD.

The freshly set up SonarQube instance comes with one admin user configured: `un: admin, pw: admin`. Once the AAD connection is established and AAD authentication is enabled, logout and validate AAD authentication. Even with AAD connected you can still login using the initial admin account. We will still need the admin account to allow 3rd party apps to access the API. Therefore generate a strong password and immediately store it in our key vault.

```bash
az keyvault secret set --vault-name $YOUR_KEY_VAULT --name 'sonarqube-app-admin' --value '<VALUE>'
az keyvault secret set --vault-name $YOUR_KEY_VAULT --name 'sonarqube-app-admin-password' --value '<VALUE>'
```

## Final step: Connect SonarQube to VSTS

That's the reason we are here: we want to integrate SonarQube into CI! At least we want continuous analysis & reporting about our app codebase's quality. And we might even want to give SonarQube voting power when it comes to successful/unsuccessful builds.

The official SonarQube docs offer comprehensive step-by-step guides to connect a SonarQube instance.

* [Creating a SonarQube API token](https://docs.sonarqube.org/display/SONAR/User+Token)
* [Setting up a VSTS service connection](https://docs.sonarqube.org/display/SCAN/SonarQube+Endpoint)
* [Use of the SonarQube extension in VSTS](https://docs.sonarqube.org/display/SCAN/Analyzing+with+SonarQube+Extension+for+VSTS-TFS)

When integrated successfully, SonarQube adds a new tile to the build summary page stating analysis results and containing a link to the detailed reports in SonarQube. To access these the user has to be added to the App Registration in AAD.

![image](https://user-images.githubusercontent.com/6577198/44949541-07f79a80-ae34-11e8-84e2-4c06474da20f.png)

This is it! Thanks for reading all the way through.

Adrian
