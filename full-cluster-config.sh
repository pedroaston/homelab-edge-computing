# (1st - all nodes): Install kubelet, kubeadm and kubectl

# Prepare installation
sudo apt install curl apt-transport-https -y
curl -fsSL  https://packages.cloud.google.com/apt/doc/apt-key.gpg|sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/k8s.gpg
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
# Install Packets
sudo apt update
sudo apt install wget curl vim git kubelet kubeadm kubectl -y
sudo apt-mark hold kubelet kubeadm kubectl
# Confirm install
kubectl version --client && kubeadm version

# (2nd - all nodes): Disable swap space

# Disable all swaps from /proc/swaps
sudo swapoff -a
# Confirm
free -h
# Disable permanently by commenting the following line
sudo vim /etc/fstab
/swap.img	none	swap	sw	0	0 # Comment this
# Confirm settings
sudo mount -a
free -h
# Enable kernel modules
sudo modprobe overlay
sudo modprobe br_netfilter
# Add some settings to sysctl
sudo tee /etc/sysctl.d/kubernetes.conf<<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
# Reload sysctl
sudo sysctl --system

# (3rd - all nodes): Install Container runtime >> Docker (My choice)

# Add repo and Install packages
sudo apt update
sudo apt install -y curl gnupg2 software-properties-common apt-transport-https ca-certificates
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
sudo apt update
sudo apt install -y containerd.io docker-ce docker-ce-cli
# Create required directories
sudo mkdir -p /etc/systemd/system/docker.service.d
# Create daemon json config file
sudo tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
# Start and enable Services
sudo systemctl daemon-reload 
sudo systemctl restart docker
sudo systemctl enable docker
# Configure persistent loading of modules
sudo tee /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
# Ensure you load modules
sudo modprobe overlay
sudo modprobe br_netfilter
# Set up required sysctl params
sudo tee /etc/sysctl.d/kubernetes.conf<<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

# (4th - all nodes): Install Mirantis' Docker shim (Requirement for docker in kubernetes)

# Ensure docker is running
systemctl status docker
# Fetch the latest version tag
VER=$(curl -s https://api.github.com/repos/Mirantis/cri-dockerd/releases/latest|grep tag_name | cut -d '"' -f 4|sed 's/v//g')
echo $VER
# Fetch for Intel 64-bit CPU
wget https://github.com/Mirantis/cri-dockerd/releases/download/v${VER}/cri-dockerd-${VER}.amd64.tgz
tar xvf cri-dockerd-${VER}.amd64.tgz
# Move to /usr/local/bin/
sudo mv cri-dockerd/cri-dockerd /usr/local/bin/
rm -r cri-dockerd/cri-dockerd
# Confirm install
cri-dockerd --version
# Configure systemd units for cri-dockerd
wget https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.service
wget https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.socket
sudo mv cri-docker.socket cri-docker.service /etc/systemd/system/
sudo sed -i -e 's,/usr/bin/cri-dockerd,/usr/local/bin/cri-dockerd,' /etc/systemd/system/cri-docker.service
# Start and enable the services
sudo systemctl daemon-reload
sudo systemctl enable cri-docker.service
sudo systemctl enable --now cri-docker.socket
# Confirm the service is running
systemctl status cri-docker.socket

# (5th - master node): Initialize control plane

# Make sure that the br_netfilter module is loaded
lsmod | grep br_netfilter
# Enable kubelet service
sudo systemctl enable kubelet
# Pull container images
sudo kubeadm config images pull --cri-socket /run/cri-dockerd.sock
# Create cluster
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --cri-socket /run/cri-dockerd.sock
# Configure kubectl
mkdir -p $HOME/.kube
sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
# Check cluster status:
kubectl cluster-info

# (6th - master node): 

# Install the Tigera Calico operator
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml
# Install Calico by creating the necessary custom resource
wget https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/custom-resources.yaml
vim custom-resources.yaml # make sure the CIDR is 10.244.0.0/16
kubectl create -f custom-resources.yaml
# Confirm that pods are all running (may take 2 minutes)
watch kubectl get pods -n calico-system
# Remove the taints on the control plane
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
# Confirm that you now have a node in your cluster
kubectl get nodes -o wide

# (7th - worker nodes): Add worker nodes

# Join cluster
sudo kubeadm join <controlnode-ip>:6443 --cri-socket /run/cri-dockerd.sock --token xn4v7c.bzgh43k0t4vyqbuq \
  --discovery-token-ca-cert-hash sha256:b9bf08b24e5f3bf709122fd009418ccf600bc4b97546adc73e05bfa40601362d
# Confirm in control node that the workers were added
kubectl get nodes