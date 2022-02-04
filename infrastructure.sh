

function connectivity_check {
    public_ips=`az vm list-ip-addresses -g ${rg} --query "[].virtualMachine.network.publicIpAddresses[].ipAddress" -o tsv`
    private_ips=`az vm list-ip-addresses -g ${rg} --query "[].virtualMachine.network.privateIpAddresses" -o tsv`

    for public_ip in $public_ips; do
        echo "--------------------${public_ip}----------------------------------------"
        for private_ip in $private_ips; do
            echo "--------------------${private_ip}"
            ssh -o StrictHostKeyChecking=no azureadmin@$public_ip ping -c 4 $private_ip
        done
    done
}

az login
az account set

export rg="VWAN001"
export vwan_name="VWAN"
export location="eastus2"
export vhub0_name="eastus2"

az group create --name ${rg} --location ${location}

echo "Creating VWAN and VHUB"

az network vwan create --name ${vwan_name} --resource-group ${rg} --type Standard --location ${location}

az network vhub create --address-prefix 10.100.0.0/24 \
                        --name ${vhub0_name} \
                        --resource-group ${rg} \
                        --vwan ${vwan_name}   

echo "Creating Workload VNETs and Shared Services"
                        
az network vnet create --name "BLUE0" \
                        --resource-group ${rg} \
                        --address-prefixes 10.0.0.0/16 \
                        --subnet-name default \
                        --subnet-prefixes 10.0.1.0/24 \
                        --location ${location}


az network vnet create --name "BLUE1" \
                        --resource-group ${rg} \
                        --address-prefixes 10.1.0.0/16 \
                        --subnet-name default \
                        --subnet-prefixes 10.1.1.0/24 \
                        --location ${location}

az network vnet create --name "GREEN0" \
                        --resource-group ${rg} \
                        --address-prefixes 10.2.0.0/16 \
                        --subnet-name default \
                        --subnet-prefixes 10.2.1.0/24 \
                        --location ${location}

az network vnet create --name "GREEN1" \
                        --resource-group ${rg} \
                        --address-prefixes 10.3.0.0/16 \
                        --subnet-name default \
                        --subnet-prefixes 10.3.1.0/24 \
                        --location ${location}

az network vnet create --name "SHAREDSERVICES" \
                        --resource-group ${rg} \
                        --address-prefixes 10.4.0.0/16 \
                        --subnet-name default \
                        --subnet-prefixes 10.4.1.0/24 \
                        --location ${location}


echo "Create VM for testing"

for vnet in BLUE0 BLUE1 GREEN0 GREEN1 SHAREDSERVICES; do \

    az vm create --resource-group ${rg} \
                                --name "${vnet}VM" \
                                --image UbuntuLTS \
                                --vnet-name $vnet \
                                --subnet default \
                                --admin-username azureadmin \
                                --public-ip-sku Standard \
                                --ssh-key-values @~/.ssh/id_rsa.pub \
                                --nsg-rule SSH 
done

echo "Create Route Tables"

az network vhub route-table create --name BLUE \
                                    --resource-group ${rg} \
                                    --vhub-name ${vhub0_name}
                                    

az network vhub route-table create --name GREEN \
                                    --resource-group ${rg} \
                                    --vhub-name ${vhub0_name}


az network vhub route-table create --name SHAREDSERVICES \
                                    --resource-group ${rg} \
                                    --vhub-name ${vhub0_name}

echo "Creating full mesh"

ss_rtid=`az network vhub route-table show --name SHAREDSERVICES -g ${rg} --vhub-name ${vhub0_name} --query "id" -o tsv`
blue_rtid=`az network vhub route-table show --name BLUE -g ${rg} --vhub-name ${vhub0_name} --query "id" -o tsv`
green_rtid=`az network vhub route-table show --name GREEN -g ${rg} --vhub-name ${vhub0_name} --query "id" -o tsv`

az network vhub connection create --name SHAREDSERVICES \
                                    --remote-vnet SHAREDSERVICES \
                                    --resource-group ${rg} \
                                    --vhub-name ${vhub0_name} \
                                    --associated-route-table ${ss_rtid}\
                                    --propagated-route-tables ${ss_rtid} ${blue_rtid} ${green_rtid}

for color in BLUE GREEN ; do
    for id in 0 1 ; do 
        vnet="${color}${id}"
        rtid=`az network vhub route-table show --name ${color} -g ${rg} --vhub-name ${vhub0_name} --query "id" -o tsv`
        az network vhub connection create --name ${vnet} \
                                            --remote-vnet "${vnet}" \
                                            --resource-group ${rg} \
                                            --vhub-name ${vhub0_name} \
                                            --associated-route-table ${rtid} \
                                            --propagated-route-tables ${ss_rtid} ${blue_rtid} ${green_rtid}
    done
done

echo "Verifying connectivity"

connectivity_check

echo "Creating isolation"

ss_rtid=`az network vhub route-table show --name SHAREDSERVICES -g ${rg} --vhub-name ${vhub0_name} --query "id" -o tsv`
blue_rtid=`az network vhub route-table show --name BLUE -g ${rg} --vhub-name ${vhub0_name} --query "id" -o tsv`
green_rtid=`az network vhub route-table show --name GREEN -g ${rg} --vhub-name ${vhub0_name} --query "id" -o tsv`

az network vhub connection create --name SHAREDSERVICES \
                                    --remote-vnet SHAREDSERVICES \
                                    --resource-group ${rg} \
                                    --vhub-name ${vhub0_name} \
                                    --associated-route-table ${ss_rtid} \
                                    --propagated-route-tables ${ss_rtid} ${blue_rtid} ${green_rtid}

for color in BLUE GREEN ; do

    rt=${color}
    rtid=`az network vhub route-table show --name $rt -g ${rg} --vhub-name ${vhub0_name} --query "id" -o tsv`

    for id in 0 1 ; do 

        vnet="${color}${id}"

        echo $vnet $rt $rtid

        #az network vhub connection delete --name ${vnet} -g ${rg} --vhub-name ${vhub0_name} --yes

        az network vhub connection create --name ${vnet} \
                                            --remote-vnet "${vnet}" \
                                            --resource-group ${rg} \
                                            --vhub-name ${vhub0_name} \
                                            --associated-route-table ${rtid} \
                                            --propagated-route-tables ${rtid} ${ss_rtid}

    done

done

echo "Verifying connectivity"

connectivity_check


echo "Additional commands to explore"

az network vhub connection list --resource-group ${rg} --vhub-name ${vhub0_name}

az network vhub route-table show --name defaultRouteTable --resource-group ${rg} --vhub-name ${vhub0_name}

az network vhub route-table list --resource-group ${rg} --vhub-name ${vhub0_name}

az network vhub route-table show --name defaultRouteTable --resource-group ${rg} --vhub-name ${vhub0_name}
