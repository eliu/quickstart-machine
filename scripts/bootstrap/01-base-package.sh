#!/usr/bin/env bash
set -e

MACHINE_IP="$1"
TEMPDIR="$(mktemp -d)"
ALIYUN_MIRROR="https://mirrors.aliyun.com"
REPO_BASE="$ALIYUN_MIRROR/repo/Centos-7.repo"
REPO_EPEL="$ALIYUN_MIRROR/repo/epel-7.repo"
REPO_IUS="$ALIYUN_MIRROR/ius/ius-7.repo"
M2_MAJOR="3"
M2_VERSION="3.3.9"
NODE_VERSION="12.18.3"
NODE_FILENAME="node-v${NODE_VERSION}-linux-x64"
DOCKER_VERSION="17.09"
COMPOSE_VERSION="1.24.1"

# 初始化公共环境变量及函数
. /vagrant/scripts/common/profile.env

# ----------------------------------------------------------------
# 设置环境变量
# ----------------------------------------------------------------
setup_env() {
  info "Setting up environment ..."
  cat > /etc/profile.d/quickstart.sh << EOF
export MAVEN_HOME=/opt/apache-maven-${M2_VERSION}
export PATH=\$MAVEN_HOME/bin:/opt/${NODE_FILENAME}/bin:/usr/local/bin:\$PATH
export JAVA_HOME=$(readlink -f /etc/alternatives/java_sdk_openjdk)
export TZ=Asia/Shanghai
EOF
  . /etc/profile > /dev/null
}

# ----------------------------------------------------------------
# 设置地址IP映射
# ----------------------------------------------------------------
setup_hosts() {
  info "Setting up machine hosts ..."
  if ! cat /etc/hosts | grep dev.$APP_DOMAIN > /dev/null; then
    cat >> /etc/hosts << EOF
$MACHINE_IP dev.$APP_DOMAIN
$MACHINE_IP db.$APP_DOMAIN
$MACHINE_IP redis.$APP_DOMAIN
$MACHINE_IP file.$APP_DOMAIN
EOF
  fi
  hostnamectl set-hostname dev.$APP_DOMAIN
}

# ----------------------------------------------------------------
# 解决 DNS 无法解析导致安装包超时的问题
# ----------------------------------------------------------------
resolve_dns() {
  info "Resolving DNS ..."
  for nameserver in $(cat /vagrant/user-config/nameserver.conf); do
    info "Resolving DNS by adding nameserver $nameserver ..."
    nmcli con mod enp0s3 +ipv4.dns $nameserver
  done
  systemctl restart NetworkManager
}

# ----------------------------------------------------------------
# 替换默认的软件源
# ----------------------------------------------------------------
accelerate_yum_repo() {
  info "Setting up yum repo ..."
  # mv /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.backup
  rm -fr /etc/yum.repos.d/*.repo
  curl -sSL $REPO_BASE -o /etc/yum.repos.d/CentOS-Base.repo
  sed -i -e '/mirrors.cloud.aliyuncs.com/d' \
         -e '/mirrors.aliyuncs.com/d' \
         /etc/yum.repos.d/CentOS-Base.repo
  curl -sSL $REPO_EPEL -o /etc/yum.repos.d/epel.repo
  curl -sSL $REPO_IUS -o /etc/yum.repos.d/ius.repo
  sed -i 's repo.ius.io mirrors.aliyun.com/ius/ g' /etc/yum.repos.d/ius.repo
  yum clean all
  yum makecache fast
}

# ----------------------------------------------------------------
# 安装基础依赖包
# ----------------------------------------------------------------
install_base_packages() {
  info "Installing base packages ..."
  yum install -y \
    gcc \
    pcre \
    pcre-devel \
    zlib \
    zlib-devel \
    openssl \
    openssl-devel \
    java-1.8.0-openjdk-devel \
    yum-utils \
    git224 \
    vim
}

# ----------------------------------------------------------------
# 安装 Node.js
# ----------------------------------------------------------------
install_frontend_packages() {
  local download_url=https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/v${NODE_VERSION}/${NODE_FILENAME}.tar.xz
  info "Installing node and npm ..."
  info "Downloading ${download_url}"
  curl -sSL ${download_url} -o "${TEMPDIR}/${NODE_FILENAME}.tar.xz"
  tar xf "${TEMPDIR}/${NODE_FILENAME}.tar.xz" -C /opt
  # 安装依赖的前端工具
  info "Installing yarn and lerna ..."
  npm install -g yarn lerna --registry=https://registry.npm.taobao.org
}

# ----------------------------------------------------------------
# 安装 Docker
# ----------------------------------------------------------------
install_docker() {
  if command_exists docker; then
    info "Docker has been previously installed."
  else
    info "Enable iptables routing ..."
    cat > /etc/sysctl.d/docker.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
    sysctl --system > /dev/null

    info "Installing docker ..."
    {
      # https://yq.aliyun.com/articles/110806?spm=a2c4e.11153940.0.0.108e435aDMp0n2&p=4#comments
      export VERSION=$DOCKER_VERSION
      curl -sSL https://get.docker.com | bash -s docker --mirror Aliyun
    }
    usermod -aG docker vagrant
    systemctl enable docker
    mkdir -p /etc/docker
    cp -f /vagrant/user-config/docker-daemon.json /etc/docker/daemon.json
    systemctl restart docker
  fi
}

# 安装 Docker Compose
install_compose() {
  if command_exists docker-compose; then
    info "Docker Compose has been previously installed."
  else
    info "Installing Docker Compose ..."
    # yum -y install python-pip
    # # pip install --upgrade pip
    # python -m pip install -U pip
    # pip install docker-compose
    curl -sSL \
      https://get.daocloud.io/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-`uname -s`-`uname -m` \
      > /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  fi
}

# ----------------------------------------------------------------
# 安装 Maven
# ----------------------------------------------------------------
install_maven() {
  if command_exists mvn; then
    info "Maven has been previously installed."
  else
    info "Installing Maven ..."
    local download_url=http://mirrors.tuna.tsinghua.edu.cn/apache/maven/maven-${M2_MAJOR}/${M2_VERSION}/binaries/apache-maven-${M2_VERSION}-bin.tar.gz
    info "Downloading ${download_url}"
    curl -sSL ${download_url} -o "${TEMPDIR}/apache-maven-${M2_VERSION}-bin.tar.gz"
    info "Extracting files to /opt ..."
    tar zxf "${TEMPDIR}/apache-maven-${M2_VERSION}-bin.tar.gz" -C /opt > /dev/null
    # 配置国内源
    mkdir -p $VAGRANT_HOME/.m2
    cp /vagrant/user-config/maven-settings.xml $VAGRANT_HOME/.m2/settings.xml
    chown -R vagrant:vagrant $VAGRANT_HOME/.m2
  fi
}

# ----------------------------------------------------------------
# 确认所有软件的版本
# ----------------------------------------------------------------
verify_versions() {
  info "Verifying package versions ..."
  echo "Node   version: $(node -v)"
  echo "NPM    version: $(npm -v)"
  echo "lerna  version: $(lerna -v)"
  echo "yarn   version: $(yarn -v)"
  echo "java   version: $(java -version 2>&1 | head -n 1 | awk -F'"' '{print $2}')"
  echo "mvn    version: $(mvn -version | head -n 1 | awk '{print $3}')"
  echo "git    version: $(git version | awk '{print $3}')"
  echo "docker version: $(docker version | grep Version | head -n 1 | awk '{print $2}')"
  docker-compose version
}

{
  DEBUG set -x
  setup_env
  setup_hosts
  # resolve_dns
  accelerate_yum_repo
  install_base_packages
  install_frontend_packages
  install_docker
  install_compose
  install_maven
  verify_versions
  DEBUG set +x
}
