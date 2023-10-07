#!/bin/zsh

# This script will deploy an AKS cluster with an application gateway and deploy a MongoDB and Mongo Express instance to the cluster
# based on directions found here: https://learn.microsoft.com/en-us/azure/application-gateway/tutorial-ingress-controller-add-on-new

# Generate a random string to make sure the names are unique
RND=$(openssl rand -base64 4 | tr -dc 'a-zA-Z0-9' | head -c 4)

# Create the variables including the random string
RG_NAME="rg-aks-demo-$RND"
LOCATION="eastus"
CLUSTER_NAME="aks-demo-cluster-$RND"
APP_GATEWAY_NAME="aks-demo-appgw-$RND"
PUBLIC_IP_NAME="aks-demo-pip-$RND"
VNET_NAME="aks-demo-vnet-$RND"
SUBNET_NAME="aks-demo-subnet-$RND"
APP_GATEWAY_NAME="aks-demo-appgw-$RND"
APPGATEWAYTOAKSPEER="AppGWtoAKSVnetPeering$RND"
AKSTOAPPGWPEER="AKStoAppGWVnetPeering$RND"

echo "Create the resource group and AKS cluster"
az group create --name $RG_NAME --location $LOCATION
az aks create -n $CLUSTER_NAME \
              -g $RG_NAME \
              --network-plugin azure \
              --enable-managed-identity \
              --generate-ssh-keys

echo "Create the public IP"
az network public-ip create -n $PUBLIC_IP_NAME \
                            -g $RG_NAME \
                            --allocation-method Static \
                            --sku Standard

echo "Create the VNet"
az network vnet create -n $VNET_NAME \
                       -g $RG_NAME \
                       --address-prefix 10.0.0.0/16 \
                       --subnet-name $SUBNET_NAME \
                       --subnet-prefix 10.0.0.0/24 

# Create the application gateway
az network application-gateway create -n $APP_GATEWAY_NAME \
                                      -g $RG_NAME \
                                      --sku Standard_v2 \
                                      --public-ip-address $PUBLIC_IP_NAME \
                                      --vnet-name $VNET_NAME \
                                      --subnet $SUBNET_NAME \
                                      --priority 100

echo "Enable the ingress-appgw addon"
appgwId=$(az network application-gateway show -n $APP_GATEWAY_NAME -g $RG_NAME -o tsv --query "id") 
echo "appgwId: $appgwId"
az aks enable-addons -n $CLUSTER_NAME \
                     -g $RG_NAME \
                     -a ingress-appgw \
                     --appgw-id $appgwId

nodeResourceGroup=$(az aks show -n $CLUSTER_NAME -g $RG_NAME -o tsv --query "nodeResourceGroup")
echo "nodeResourceGroup: $nodeResourceGroup"

aksVnetName=$(az network vnet list -g $nodeResourceGroup -o tsv --query "[0].name")
echo "aksVnetName: $aksVnetName"

echo "Create the peering between the App Gateway VNet and the AKS VNet"
aksVnetId=$(az network vnet show -n $aksVnetName -g $nodeResourceGroup -o tsv --query "id")
echo "aksVnetId: $aksVnetId"
az network vnet peering create -n $APPGATEWAYTOAKSPEER \
                               -g $RG_NAME \
                               --vnet-name $VNET_NAME \
                               --remote-vnet $aksVnetId \
                               --allow-vnet-access

echo "Create the peering between the App Gateway VNet and the AKS VNet"
appGWVnetId=$(az network vnet show -n $VNET_NAME -g $RG_NAME -o tsv --query "id")
az network vnet peering create -n $AKSTOAPPGWPEER \
                               -g $nodeResourceGroup \
                               --vnet-name $aksVnetName \
                               --remote-vnet $appGWVnetId \
                               --allow-vnet-access

echo "Generate a script that can be run to cleanup the resources and make it executable"
cat << EOF > undeploy-aks.zsh
az group delete --name $RG_NAME --yes
EOF
chmod +x undeploy-aks.zsh

echo "Get the credentials for the AKS cluster"
az aks get-credentials -n $CLUSTER_NAME -g $RG_NAME

echo "Deploy the resources to the AKS cluster"
kubectl apply -f mongo-secret.yaml
kubectl apply -f mongodb-configmap.yaml
kubectl apply -f mongo.yaml
kubectl apply -f mongo-express.yaml


# give the system a few seconds to create the service.
sleep 10

# Get the external IP address
extip=$(kubectl get service mongo-express-service | awk 'FNR==2{print $4}')

# Open the Mongo Express UI in the browser
open "http://$extip:8081"

# Let the user know what the username and password are
echo "use admin / pass to login"
