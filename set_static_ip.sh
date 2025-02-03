#!/bin/bash

# This script allows users to configure network settings on a Linux system.
# It provides options to set a static IP address or switch to a dynamic IP address.
# The script detects the operating system and checks if it is Ubuntu-based.
# It lists available network adapters and allows the user to select one for configuration.
# The script also calculates the valid IP address range based on the current subnet.

# Function to display the current operating system information
function display_os_info {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME=$NAME
        OS_VERSION=$VERSION
        OS_ID=$ID
        OS_ID_LIKE=$ID_LIKE
        OS_PRETTY_NAME=$PRETTY_NAME
        UBUNTU_CODENAME=$VERSION_CODENAME
    else
        echo "Unsupported Linux distribution."
        exit 1
    fi

    echo "Detected OS: $OS_PRETTY_NAME"
    echo "OS Name: $OS_NAME"
    echo "OS Version: $OS_VERSION"
    echo "OS ID: $OS_ID"
    echo "OS ID Like: $OS_ID_LIKE"
    echo "Ubuntu Codename: ${UBUNTU_CODENAME:-Not Available}"
}

# Function to display the current IP configuration
function display_ip_configuration {
    echo ""
    echo "Current IP Configuration:"
    for NIC in $(ls /sys/class/net/); do
        IP_INFO=$(ip addr show $NIC | grep 'inet ' | awk '{print $2}')
        GATEWAY=$(ip route | grep default | awk '{print $3}')
        
        if [[ -n "$IP_INFO" ]]; then
            NETMASK=$(ip addr show $NIC | grep 'inet ' | awk '{print $2}' | cut -d'/' -f2)
            echo "Adapter Name: $NIC"
            echo "IP Address: $IP_INFO"
            echo "Netmask: $NETMASK"
            echo "Gateway: $GATEWAY"
            echo ""
        else
            echo "Adapter Name: $NIC"
            echo "IP Address: Not Assigned"
            echo "Netmask: Not Applicable"
            echo "Gateway: $GATEWAY"
            echo ""
        fi
    done
}

# Function to display the script purpose
function display_script_info {
    echo "This script allows you to configure network settings on your Linux system."
    echo "You can set a static IP address or switch to a dynamic IP address."
    echo "Please follow the prompts to make your selections."
    echo ""
}

# Function to display the main menu
function main_menu {
    clear
    display_script_info
    display_os_info
    display_ip_configuration
    echo "Main Menu:"
    echo "1) Set Static IP"
    echo "2) Set Dynamic IP"
    echo "M) Main Menu"
    echo "B) Back to Previous Menu"
    echo "Q) Quit"
    read -p "Please enter your choice: " choice
    case $choice in
        1) set_static_ip ;;
        2) set_dynamic_ip ;;
        M|m) restart_script ;;
        B|b) previous_menu ;;
        Q|q) exit 0 ;;
        *) echo "Invalid option. Please try again." ; main_menu ;;
    esac
}

# Function to restart the script
function restart_script {
    clear
    display_script_info
    display_os_info
    display_ip_configuration
    main_menu
}

# Function to go back to the previous menu
function previous_menu {
    echo "Returning to the main menu..."
    main_menu
}

# Function to calculate subnet range
function calculate_subnet_range {
    local subnet=$1
    local netmask=$2
    IFS='.' read -r i1 i2 i3 i4 <<< "$subnet"
    if [[ "$netmask" -eq 24 ]]; then
        echo "You can set a static IP address in the range: ${i1}.${i2}.${i3}.1 - ${i1}.${i2}.${i3}.254"
    elif [[ "$netmask" -eq 16 ]]; then
        echo "You can set a static IP address in the range: ${i1}.${i2}.1.1 - ${i1}.${i2}.254.254"
    elif [[ "$netmask" -eq 8 ]]; then
        echo "You can set a static IP address in the range: ${i1}.1.1.1 - ${i1}.255.255.254"
    else
        echo "Unsupported subnet mask. Please check your network configuration."
    fi
}

# Function to set static IP
function set_static_ip {
    clear
    NICs=($(ls /sys/class/net/))
    echo "Available Network Adapters:"
    for i in "${!NICs[@]}"; do
        echo "$((i + 1))) ${NICs[i]}"
    done
    echo "M) Main Menu"

    read -p "Select the network adapter number (starting from 1) or M to return to the main menu: " nic_choice
    if [[ "$nic_choice" == "M" || "$nic_choice" == "m" ]]; then
        main_menu
    fi

    NIC=${NICs[$((nic_choice - 1))]}

    if [[ -z "$NIC" ]]; then
        echo "Invalid NIC selection."
        main_menu
    fi

    echo "You have selected the network adapter: $NIC"

    IP_INFO=$(ip addr show $NIC | grep 'inet ' | awk '{print $2}')
    GATEWAY=$(ip route | grep default | awk '{print $3}')
    echo "Current IP address: ${IP_INFO:-Not Assigned}"
    echo "Gateway: $GATEWAY"

    if [[ -n "$IP_INFO" ]]; then
        NETMASK=$(ip addr show $NIC | grep 'inet ' | awk '{print $2}' | cut -d'/' -f2)
        calculate_subnet_range "$(echo $IP_INFO | cut -d'/' -f1)" "$NETMASK"
    else
        echo "No current IP assigned. You can set a static IP address in the range: $GATEWAY"
    fi

    read -p "Would you like to set a static IP address? (y/n): " set_static
    if [[ "$set_static" == "y" ]]; then
        read -p "Enter the static IP address (within the range): " static_ip
        echo "Checking for netplan configuration files..."
        CONFIG_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n 1)
        if [[ -z "$CONFIG_FILE" ]]; then
            echo "No netplan configuration file found. Is netplan used to set IP addresses on this server? (y/n)"
            read -p "Your choice: " use_netplan
            if [[ "$use_netplan" == "y" ]]; then
                echo "Please create a netplan configuration file manually."
                main_menu
            else
                echo "Setting static IP using an alternative method..."
                set_static_ip_alternative "$NIC" "$static_ip" "$GATEWAY"
                return
            fi
        fi
        
        echo "Setting static IP for $NIC on Ubuntu using $CONFIG_FILE..."
        sudo bash -c "cat > $CONFIG_FILE <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $NIC:
      dhcp4: no
      addresses: [$static_ip/$(ipcalc -m $static_ip $GATEWAY | cut -d' ' -f4)]
      gateway4: $GATEWAY
EOF"
        echo "Static IP address set successfully. Please apply the changes with the command: sudo netplan apply"
        
        # Restart the network manager
        echo "Restarting the network manager..."
        sudo systemctl restart NetworkManager
        
        # Re-run the script
        main_menu
    else
        echo "Static IP address configuration canceled."
    fi
    main_menu
}

# Function to set static IP using an alternative method
function set_static_ip_alternative {
    local nic=$1
    local static_ip=$2
    local gateway=$3

    echo "Configuring static IP for $nic using /etc/network/interfaces..."
    sudo bash -c "cat >> /etc/network/interfaces <<EOF
auto $nic
iface $nic inet static
    address $static_ip
    netmask 255.255.255.0
    gateway $gateway
EOF"
    echo "Static IP address set successfully using /etc/network/interfaces."
    
    # Restart the network manager
    echo "Restarting the network manager..."
    sudo systemctl restart NetworkManager
    
    # Re-run the script
    main_menu
}

# Function to set dynamic IP
function set_dynamic_ip {
    clear
    NICs=($(ls /sys/class/net/))
    echo "Available Network Adapters:"
    for i in "${!NICs[@]}"; do
        echo "$((i + 1))) ${NICs[i]}"
    done
    echo "M) Main Menu"

    read -p "Select the network adapter number (starting from 1) or M to return to the main menu: " nic_choice
    if [[ "$nic_choice" == "M" || "$nic_choice" == "m" ]]; then
        main_menu
    fi

    NIC=${NICs[$((nic_choice - 1))]}

    if [[ -z "$NIC" ]]; then
        echo "Invalid NIC selection."
        main_menu
    fi

    echo "You have selected the network adapter: $NIC"
    echo "Setting dynamic IP for $NIC..."

    if [[ "$OS_ID" == "ubuntu" || "$OS_ID_LIKE" == *"ubuntu"* ]]; then
        CONFIG_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n 1)
        if [[ -z "$CONFIG_FILE" ]]; then
            echo "No netplan configuration file found. Please ensure you are using a supported Ubuntu version."
            main_menu
        fi
        
        echo "Configuring $NIC to use DHCP in $CONFIG_FILE..."
        sudo bash -c "cat > $CONFIG_FILE <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $NIC:
      dhcp4: yes
EOF"
        echo "Dynamic IP configuration set successfully. Please apply the changes with the command: sudo netplan apply"
        
        # Restart the network manager
        echo "Restarting the network manager..."
        sudo systemctl restart NetworkManager
        
        # Re-run the script
        main_menu
    else
        echo "This script only supports Ubuntu-based systems."
    fi
    main_menu
}

# Start the script by displaying the main menu
main_menu
