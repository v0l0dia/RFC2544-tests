#!/bin/bash

# Установка библиотек зависимостей
sudo apt-get --assume-yes install make
sudo apt-get --assume-yes install gcc
sudo apt-get --assume-yes install linux-headers-$(uname -r)
sudo apt-get --assume-yes install python3-pip
sudo apt-get --assume-yes install mc
sudo apt-get --assume-yes install iperf3
sudo apt-get --assume-yes install tcpreplay
sudo apt-get --assume-yes install pkg-config
sudo apt-get --assume-yes install libsystemd-dev
sudo apt-get --assume-yes install libnuma-dev
sudo apt-get --assume-yes install libpcap-dev
sudo apt-get --assume-yes install liblua5.3-dev
sudo apt-get --assume-yes install git

# Настройка страниц памяти HugePages (общий размер 16Gb)
sudo mkdir -p /mnt/huge
sudo echo 'vm.nr_hugepages = 8192' >> /etc/sysctl.conf
sudo echo 'nodev /mnt/huge hugetlbfs defaults 0 0' >> /etc/fstab
sudo echo 8192 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# Установка и настройка вспомогательного ПО
sudo -H pip3 install scapy
pip3 install meson
pip3 install ninja
sudo -H pip3 install ninja
sudo -H pip3 install meson

# Установка и настройка инструментария DPDK
wget http://fast.dpdk.org/rel/dpdk-20.08.tar.xz
tar xf ./dpdk-20.08.tar.xz
(cd ~/ddpdk-20.08 && meson build)
(cd ~/dpdk-20.08/build && ninja)
(cd ~/dpdk-20.08/build && sudo ninja install)
sudo ldconfig

# Установка и настройка инструментария PktGen
git clone https://github.com/pktgen/Pktgen-DPDK.git
(cd ~/Pktgen-DPDK && make buildlua)
(cd ~/Pktgen-DPDK/Builddir && sudo ninja install)

# Установка тестов RFC2544
mkdir -p test
git clone https://github.com/v0l0dia/RFC2544-tests.git
cd ~/RFC2544-tests && cp ./*.lua ~/test && cp ./Pktgen.lua ~/test && cp mux_ports.cfg ~/mux_ports.cfg
cd ~ && rm -r -f ~/RFC2544-tests
