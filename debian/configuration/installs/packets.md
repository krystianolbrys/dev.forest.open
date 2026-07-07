# basic
sudo apt install curl wget htop btop lm-sensors stress-ng tree xxd

# docker
sudo apt install docker.io docker-compose docker-buildx
sudo usermod -aG docker dev
sudo docker run -it --rm ubuntu bash -c 'apt update'

# KVM
sudo apt install qemu-system libvirt-daemon-system ovmf virt-manager
sudo usermod -aG libvirt dev
