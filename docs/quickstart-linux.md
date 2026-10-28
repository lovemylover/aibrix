# AIBrix Linux 一键安装教程

这份教程面向**第一次接触 AIBrix 的 Linux 用户**。你只需要一台 Linux 机器（裸机、VM、云主机均可），跟着下面 4 步走，**5 分钟左右**就能在本地或自有 Kubernetes 集群上跑通 AIBrix + 一个 sglang PD 引擎的 Mock 模型，发请求验证端到端链路。

教程覆盖三种典型场景：

- **场景 A**：本机用 Kind 起一个临时 K8s 集群（最简单，零依赖现有集群）
- **场景 B**：你已有 K8s 集群（自建/云厂商/Minikube 等），把 AIBrix 装上去
- **场景 C**：纯验证安装，不部署 Mock 模型，只起 aibrix 控制面 + Gateway

---

## 0. 选择场景

| 你的情况 | 推荐场景 | 命令 |
|---------|---------|------|
| Linux 机器有 Docker，但没 K8s 集群 | A（Kind） | `./install.sh` |
| 已经有 K8s 集群，有 push 权限的镜像仓库 | B（existing） | `./install.sh --cluster existing --registry <你的仓库>` |
| 只想看 aibrix 控制面，不要 Mock | C（无 mock） | `./install.sh --mock none` |

> ⚠️ 中国大陆用户：建议先配好 docker 代理（HTTPS_PROXY）。后面 `docker pull` 都要走代理。
> 如果你用 Clash/V2Ray 之类的本地代理，端口常见为 `7897` 或 `1080`，
> `export HTTPS_PROXY=http://127.0.0.1:7897 HTTP_PROXY=http://127.0.0.1:7897` 即可。

---

## 1. 准备 Linux 环境

### 1.1 系统要求

- Linux x86_64 或 arm64（Ubuntu 20.04+ / CentOS 7+ / Debian 11+ 推荐）
- 4 GB 内存，10 GB 空闲磁盘
- 能访问 `github.com` / `registry-1.docker.io`（或配好代理）

### 1.2 安装必要工具

如果你已经装好 `docker / kubectl / go / make / jq`，可直接跳到 1.3。

Ubuntu / Debian 一键安装：

```bash
# 1. 更新 apt 索引
sudo apt update

# 2. Docker（如果还没有）
curl -fsSL https://get.docker.com/ | sudo sh
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"   # 让当前用户免 sudo 调 docker
# 重新登录一次让 group 生效：exit 然后再 ssh 进来

# 3. kubectl
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

# 4. Go 1.22+
# 选 a: 用 apt 装老版（不推荐，可能版本太老）
sudo apt install -y golang-go
# 选 b: 装最新版（推荐）
GO_VER=1.23.4
curl -LO "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz"
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf "go${GO_VER}.linux-amd64.tar.gz"
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh
source /etc/profile.d/go.sh

# 5. make + jq + curl
sudo apt install -y make jq curl

# 6. （场景 A 才需要）kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
```

CentOS / RHEL / Fedora 一键安装：

```bash
# Docker
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo yum install -y docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
# 重新登录一次让 group 生效

# kubectl
cat <<'EOF' | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF
sudo yum install -y kubectl

# Go 1.23+
GO_VER=1.23.4
curl -LO "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz"
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf "go${GO_VER}.linux-amd64.tar.gz"
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh
source /etc/profile.d/go.sh

# make + jq + curl
sudo yum install -y make jq curl

# kind（场景 A 才需要）
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
```

### 1.3 验证

```bash
docker version
kubectl version --client
go version           # 应该 >= 1.22
make --version
jq --version
kind version         # 场景 A 才需要
```

---

## 2. 拉代码

```bash
git clone https://github.com/vllm-project/aibrix.git
cd aibrix
```

如果你 fork 了仓库到 `git@github.com:yourname/aibrix.git`，可以：
```bash
git clone git@github.com:yourname/aibrix.git
cd aibrix
git remote add upstream https://github.com/vllm-project/aibrix.git
```

---

## 3. 一键安装

### 场景 A：本地 Kind 集群（推荐新手）

```bash
./install.sh
```

这一条命令做了：

1. 起 Kind 集群（K8s 1.32）
2. 用 docker build 构建 aibrix 5 个镜像（controller-manager / gateway-plugins / runtime / metadata-service / kvcache-watcher）+ vLLM mock 镜像
3. `kind load` 把镜像塞进 kind node
4. 安装 CRDs + envoy-gateway + aibrix controller
5. 起 port-forward：`localhost:8888 → envoy gateway`
6. 自动 smoke test：`GET /v1/models` 应返回 200 + 模型列表

如果你已经 build 过一次（重复跑安装），跳过 build 加速：

```bash
./install.sh --skip-build
```

如果你想只起 sglang PD 的 mock（链路清爽，便于学习）：

```bash
./install.sh --mock sglang
```

可选参数组合：

| 想要的效果 | 命令 |
|----------|------|
| 全套（aibrix + 所有 mock 引擎：vllm/sglang/trtllm/nixl/bucket + qwen3） | `./install.sh` |
| 只 sglang mock | `./install.sh --mock sglang` |
| 只 vllm mock | `./install.sh --mock vllm` |
| 只控制面，无 mock | `./install.sh --mock none` |
| 跳过 docker build（镜像已经 build 过） | `./install.sh --skip-build` |
| 远程服务器（不起 port-forward） | `./install.sh --no-port-forward` |

### 场景 B：已有 K8s 集群 + 自己的镜像仓库

前提：
- 集群里 `kubectl get nodes` 能正常返回
- 你有一个**集群所有节点都能 pull** 的镜像仓库（公网 docker hub / 内网 harbor / 自建 registry）
- 你对仓库有 push 权限

```bash
# 例子 1: 用 docker hub,你的用户名是 myname
docker login
./install.sh --cluster existing --registry docker.io/myname

# 例子 2: 内网 harbor
docker login harbor.internal.company.com
./install.sh --cluster existing --registry harbor.internal.company.com/aibrix

# 例子 3: 集群已 built-in registry（如 OpenShift 内置）
./install.sh --cluster existing --registry image-registry.openshift-image-registry.svc:5000/aibrix

# 例子 4: 镜像已经在仓库里了,跳过 build & push
./install.sh --cluster existing --registry docker.io/myname --skip-build
```

`install.sh --cluster existing` 做了什么：

1. 验证 kubectl 能连到集群
2. 构建 aibrix 镜像（除非 `--skip-build`）
3. retag + docker push 到你的仓库
4. `make install` + `make deploy AIBRIX_CONTAINER_REGISTRY_NAMESPACE=<你的仓库>`
5. 部署 envoy-gateway / redis / monitoring
6. 默认 deploy `mock-sglang-only`（除非 `--mock none`）

> ⚠️ 已有集群场景下，**集群节点要能自己拉镜像**。你的 K8s Worker 节点要能 pull `docker.io/myname/controller-manager:nightly` 等。
> 如果集群是 air-gapped，需要提前把镜像 push 到内网仓库。

### 场景 C：纯控制面（不部署 mock 模型）

适合你只想验证 aibrix controller / gateway-plugins 的工作，模型 pod 你自己起。

```bash
./install.sh --mock none
```

---

## 4. 验证安装

检查 pod：

```bash
kubectl get pods -n aibrix-system
kubectl get pods -n envoy-gateway-system
kubectl get pods -n default    # mock pod
```

预期输出（场景 A，sglang only）：

```
NAMESPACE              NAME                                          READY   STATUS    AGE
aibrix-system          aibrix-controller-manager-xxx                 1/1     Running  2m
aibrix-system          aibrix-gateway-plugins-xxx (2 副本)           1/1     Running  2m
aibrix-system          aibrix-gpu-optimizer-xxx                      1/1     Running  2m
aibrix-system          aibrix-kuberay-operator-xxx                   1/1     Running  2m
aibrix-system          aibrix-metadata-service-xxx                   1/1     Running  2m
aibrix-system          aibrix-redis-master-xxx                       1/1     Running  2m
envoy-gateway-system   envoy-aibrix-system-aibrix-eg-xxx             2/2     Running  2m
envoy-gateway-system   envoy-gateway-xxx                             1/1     Running  2m
default                mock-llama2-7b-pd-sglang-...-prefill-xxx      1/1     Running  30s
default                mock-llama2-7b-pd-sglang-...-decode-xxx       1/1     Running  30s
```

调一个 inference 请求（场景 A，port-forward 已经在 8888）：

```bash
curl http://localhost:8888/v1/models
```

期望返回 5 个模型：llama2-7b、llama2-7b-sglang、qwen3-8b、qwen3-8b-replica-inflight、qwen3-8b-replica-rps。

```bash
curl http://localhost:8888/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama2-7b-sglang",
    "messages": [{"role":"user","content":"Hello AIBrix"}],
    "max_tokens": 30
  }'
```

期望返回 200 + 一个 chat completion JSON。响应里的 `metrics.mock_pod` 字段告诉你路由到了哪个 decode pod。完整链路时序图见 [`docs/sglang-pd-request-flow.md`](sglang-pd-request-flow.md)。

场景 B（已有集群）：你的 envoy gateway 通过 LoadBalancer / Ingress 暴露，把上面的 `localhost:8888` 换成实际访问地址即可。

---

## 5. 关闭和清理

### 仅停止 port-forward（保留集群和部署）

```bash
./uninstall.sh
```

### 卸载 aibrix（保留集群）

```bash
./uninstall.sh --undeploy
```

这一步会：
- 拆掉 StormService / RoleSet (自动 patch finalizer，避免卡死)
- 删 aibrix-system / envoy-gateway-system namespace
- 删 aibrix CRD

### 删除 Kind 集群本身（场景 A）

```bash
./uninstall.sh --undeploy --delete-cluster
```

---

## 6. 常见问题

### Q1: `./install.sh` 时 `make docker-build-all` 报 `apt update 502 Bad Gateway`

这是 Debian 镜像源的临时网络问题。install.sh 已经做了**一次自动 retry**，如果还失败：

```bash
# 检查代理是否生效
echo $HTTPS_PROXY
curl -v https://registry-1.docker.io/v2/

# 多试几次或者临时换源
sudo sed -i 's|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list
```

### Q2: Go 版本 ≥ 1.26 时 `make build` 报 `invalid array length -delta * delta`

这是 Go 1.26 与 `golang.org/x/tools@v0.24.0` 的已知不兼容（项目 go.mod 仍 pin Go 1.22）。

```bash
export GOTOOLCHAIN=local
./install.sh
```

或者重新安装 Go 1.22：
```bash
GO_VER=1.22.6
curl -LO "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz"
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf "go${GO_VER}.linux-amd64.tar.gz"
```

`install.sh` 会自动检测 Go 版本并设 `GOTOOLCHAIN=local`，所以你不需要手动设置。

### Q3: kind 节点拉不到 docker hub 镜像（ImagePullBackOff）

kind 节点继承了你主机的代理 env，但代理是 `127.0.0.1:xxxx`，在节点里访问不到主机。

`install.sh` 已经处理：所有需要的镜像会在主机上 `docker pull` 之后 `kind load` 进节点。如果你看到 ImagePullBackOff，检查：

1. 主机有没有代理：`echo $HTTPS_PROXY`，`curl -v https://registry-1.docker.io/v2/`
2. 主机磁盘空间够不够（`df -h`）

### Q4: `--cluster existing` 报 `kubectl cannot reach any cluster`

你的 `~/.kube/config` 没配好，或者 cluster-info 失败。验证：

```bash
kubectl cluster-info
kubectl get nodes
```

确认能返回后再跑 `./install.sh --cluster existing --registry <你的仓库>`。

### Q5: 集群里 mock pod 一直 `ImagePullBackOff`

集群节点拉不到 `aibrix/vllm-mock:nightly`。可能原因：

1. `aibrix` 是个 docker hub namespace 但没公开镜像，节点 pull 失败
2. 你跑的是 air-gapped 集群，**没有外网**

解决方案：在你自己的镜像仓库里 push 这些镜像，然后 `kubectl edit` mock StormService，把 role template 里的 `image: aibrix/vllm-mock:nightly` 改成 `image: <你的仓库>/vllm-mock:nightly`。

### Q6: `--undeploy` 卡住不动

StormService/RoleSet 有 finalizer，等 aibrix controller 释放。修复后的 `dev-down.sh` 会**先 patch finalizer** 再 delete，正常应该是秒级返回。

如果你跑的是老版本：

```bash
# 手动 patch finalizer
kubectl patch stormservice -n default <name> -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl patch roleset -n default <name> -p '{"metadata":{"finalizers":[]}}' --type=merge
```

然后 namespace 会被 API server 立即回收。

### Q7: 想看请求是怎么走完整链路的

参考 [`docs/request-flow-sequence.md`](request-flow-sequence.md)（vLLM PD）和 [`docs/sglang-pd-request-flow.md`](sglang-pd-request-flow.md)（sglang PD），里面有 mermaid 时序图 + pod 名称级别的日志解读。

实时 trace 一次请求：

```bash
# 一边 tail gateway-plugins 日志
kubectl logs -n aibrix-system -f $(kubectl get pod -n aibrix-system -l app=gateway-plugins -o jsonpath='{.items[0].metadata.name}')

# 一边发请求
curl http://localhost:8888/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"llama2-7b-sglang","messages":[{"role":"user","content":"hi"}],"max_tokens":30}'
```

---

## 7. 后续阅读

- **架构 & 组件**：[README.md](../README.md)
- **vLLM PD 端到端时序**：[docs/request-flow-sequence.md](request-flow-sequence.md)
- **sglang PD 端到端时序**：[docs/sglang-pd-request-flow.md](sglang-pd-request-flow.md)
- **CRD 定义**：[api/](../api/)
- **配置参考**：[config/](../config/)
- **贡献指南**：[CONTRIBUTING.md](../CONTRIBUTING.md)
- **测试**：[test/README.md](../test/README.md)

---

## 8. 命令速查表

```bash
# 场景 A：本地 Kind
./install.sh                                   # 首次安装（含 build）
./install.sh --skip-build                      # 重复安装（跳过 build）
./install.sh --mock sglang                     # 只起 sglang mock
./install.sh --mock none                       # 不起任何 mock

# 场景 B：已有集群
./install.sh --cluster existing --registry docker.io/myuser

# 卸载
./uninstall.sh                                 # 停 port-forward
./uninstall.sh --undeploy                      # 卸 aibrix（保留集群）
./uninstall.sh --undeploy --delete-cluster     # 删 Kind 集群（场景 A）

# 调请求
curl http://localhost:8888/v1/models
curl http://localhost:8888/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"llama2-7b-sglang","messages":[{"role":"user","content":"hi"}],"max_tokens":30}'

# 看日志
kubectl logs -n aibrix-system -f -l app=gateway-plugins
kubectl logs -n envoy-gateway-system -f -l gateway.envoyproxy.io/owning-gateway-name=aibrix-eg -c envoy

# 看资源
kubectl get pods -A | grep -v kube-system
kubectl get stormservice -A
kubectl get httproute -A
kubectl get crd | grep aibrix.ai
```
